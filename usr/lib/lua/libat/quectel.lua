local helper = require("mobiled.scripthelpers")
local atchannel = require("atchannel")
local ubus = require("ubus")
local uloop = require("uloop")
local bit = require("bit")
local lfs = require("lfs")
local uci = require("uci")

local firmware_upgrade = require("libat.firmware_upgrade")
local session_helper = require("libat.session")
local network = require("libat.network")
local voice = require("libat.voice")
local attty = require("libat.tty")

local upgrade_dir = "/var/mobiled_upgrade"

local Mapper = {}
Mapper.__index = Mapper

local M = {}

function Mapper:get_pin_info(device, info, type)
	local ret = device:send_multiline_command('AT+QPINC?', "+QPINC:", 3000)
	if ret then
		for _, line in pairs(ret) do
			local pin_type, pin_unlock_retries, pin_unblock_retries = string.match(line, '+QPINC:%s?"(.-)",%s?(%d+),%s?(%d+)')
			if (type == "pin1" and pin_type == "SC") or (type == "pin2" and pin_type == "P2") then
				info.unlock_retries_left = pin_unlock_retries
				info.unblock_retries_left = pin_unblock_retries
			end
		end
	end
end

local function translate_pdp_type(pdp_type)
	if pdp_type == "ipv4" then
		return "1"
	elseif pdp_type == "ipv6" then
		return "2"
	else
		return "3"
	end
end

local function get_auth_parameters(profile)
	local authtype = "0" -- none
	local username = ""
	local password = ""
	if profile.authentication and profile.authentication ~= "none" and profile.username and profile.password then
		if profile.authentication == "pap" then
			authtype = "1"
		elseif profile.authentication == "chap" then
			authtype = "2"
		else -- papchap/fallback
			authtype = "3"
		end
		username = profile.username
		password = profile.password
	end
	return authtype, username, password
end

function Mapper:start_data_session(device, session_id, profile)
	local cid = session_id + 1
	local session = device.sessions[cid]
	if not session or session.proto == "ppp" then
		return true
	end

	if session.proto == "dhcp" then
		local apn = profile.apn or ""
		if not session.context_created then
			local pdptype, errMsg = session_helper.get_pdp_type(device, profile.pdptype)
			if not pdptype then
				return nil, errMsg
			end
			local authtype, username, password = get_auth_parameters(profile)
			if device:send_command(string.format('AT+QICSGP=%d,1,"%s","%s","%s",%s', cid, apn, username, password, authtype)) and device:send_command(string.format('AT+CGDCONT=%d,"%s","%s"', cid, pdptype, apn)) then
				session.context_created = true
			end
		end

		-- Reset the packet counters
		device:send_command("AT+QGDCNT=0")

		if device.network_interfaces and device.network_interfaces[cid] then
			local status = device.runtime.ubus:call("network.interface", "dump", {})
			if type(status) == "table" and type(status.interface) == "table" then
				for _, interface in pairs(status.interface) do
					if interface.device == device.network_interfaces[cid] and (interface.proto == "dhcp" or interface.proto == "dhcpv6") then
						-- A DHCP interface needs to be created before we can start the data call
						-- When no DHCP client is running, this will return an error
						local pdp_type = translate_pdp_type(profile.pdptype)
						session.pdp_type = pdp_type
						return device:send_multiline_command(string.format("AT$QCRMCALL=1,1,%s,2,%d", pdp_type, cid), "$QCRMCALL:", 300000)
					end
				end
			end
		end
		device.runtime.log:notice("Not ready to start data session yet")
	else
		device:send_command(string.format('AT+CGACT=1,%d', cid), 10000)
	end
end

function Mapper:stop_data_session(device, session_id)
	local cid = session_id + 1
	local session = device.sessions[cid]
	if not session or session.proto == "ppp" then
		return true
	end

	session.context_created = nil

	if session.proto == "dhcp" then
		if session.pdp_type then
			return device:send_command(string.format("AT$QCRMCALL=0,%d,%s", cid, session.pdp_type), 30000)
		end
		return device:send_command(string.format("AT$QCRMCALL=0,%d,%s", cid, "3"), 30000)
	end

	return device:send_command(string.format('AT+CGACT=0,%d', cid), 10000)
end

function Mapper:get_session_info(device, info, session_id)
	local cid = session_id + 1
	local session = device.sessions[cid]
	if not session then
		return true
	end

	-- Workaround for Quectel bug in session state after network deregisters
	local nas_state = network.get_state(device)
	if nas_state ~= "registered" then
		info.session_state = "disconnected"
		info.apn = nil
		return
	end

	local ret = device:send_multiline_command('AT+QMTUINFO', "+QMTUINFO")
	if ret then
		for _, line in pairs(ret) do
			local context_id, mtu4, mtu6 = line:match("^+QMTUINFO:%s?(%d+),([%d-]+),([%d-]+)$")
			if tonumber(context_id) == cid then
				if tonumber(mtu4) then
					info.mtu = tonumber(mtu4)
				end
				if tonumber(mtu6) then
					info.ipv6_mtu = tonumber(mtu6)
				end
			end
		end
	end

	ret = device:send_singleline_command(string.format('AT+QGPAPN=%d', cid), "+QGPAPN")
	if ret then
		info.apn = ret:match('^+QGPAPN:%s?%d+,"(.-)"$')
	end

	if session.proto == "dhcp" then
		info.session_state = "disconnected"
		ret = device:send_multiline_command('AT$QCRMCALL?', "$QCRMCALL:", 5000)
		if ret then
			local ipv4_state, ipv6_state
			for _, line in pairs(ret) do
				ipv4_state, ipv6_state = string.match(line, "^$QCRMCALL:%s?(%d),V4$QCRMCALL:%s?(%d),V6$")
				if ipv4_state then
					break
				end
				local state, ip_type = string.match(line, '$QCRMCALL:%s?(%d),(V%d)')
				if ip_type == "V4" then
					ipv4_state = state
				end
				if ip_type == "V6" then
					ipv6_state = state
				end
			end
			if ipv4_state == '1' then
				info.session_state = "connected"
				info.ipv4 = true
			end
			if ipv6_state == '1' then
				info.session_state = "connected"
				info.ipv6 = true
			end
		end
		if info.session_state == "connected" then
			ret = device:send_singleline_command("AT+QGDCNT?", "+QGDCNT:")
			if ret then
				local tx_bytes, rx_bytes = string.match(ret, "^+QGDCNT:%s?(%d+),(%d+)$")
				if tx_bytes then
					info.packet_counters = {
						tx_bytes = tonumber(tx_bytes),
						rx_bytes = tonumber(rx_bytes)
					}
				end
			end
		end
	end
end

function Mapper:get_network_info(device, info)
	local ret = device:send_singleline_command('AT+QENG="servingcell"', "+QENG:")
	if ret then
		local act = string.match(ret, '+QENG:%s?"servingcell",".-","(.-)"')
		local cell_id
		if act == 'LTE' then
			local tracking_area_code
			cell_id, tracking_area_code = string.match(ret, '+QENG:%s?"servingcell",".-","LTE",".-",%d+,%d+,(%x+),%d+,%d+,%d+,%d+,%d+,(%x+),[%d-]+,[%d-]+,[%d-]+,[%d-]+')
			if tracking_area_code then
				info.tracking_area_code = tonumber(tracking_area_code, 16)
			end
		elseif act == "GSM" or act == "WCDMA" then
			local location_area_code
			location_area_code, cell_id = string.match(ret, '+QENG:%s?"servingcell",".-",".-",%d+,%d+,(%x+),(%x+)')
			if location_area_code then
				info.location_area_code = tonumber(location_area_code, 16)
			end
		end
		if cell_id then
			info.cell_id = tonumber(cell_id, 16)
		end

		local service_state = string.match(ret, '+QENG:%s?"servingcell","(.-)"')
		if service_state == "SEARCH" then
			info.service_state = "no_service"
		elseif service_state == "LIMSRV" then
			info.service_state = "limited_service"
		elseif service_state == "NOCONN" or service_state == "CONNECT" then
			info.service_state = "normal_service"
		end
	end
	local err
	ret, err = device:send_multiline_command('AT+QGETMAXRATE', "+QGETMAXRATE:")
	if ret then
		for _, line in pairs(ret) do
			local max_tx_rate, max_rx_rate = string.match(line, '^+QGETMAXRATE:%s?1,".-",(%d+),(%d+)$')
			if max_tx_rate then
				info.connection_rate = {
					max_tx_rate = tonumber(max_tx_rate),
					max_rx_rate = tonumber(max_rx_rate)
				}
			end
		end
	elseif err ~= "blacklisted" then
		table.insert(device.command_blacklist, 'AT%+QGETMAXRATE')
	end
end

local function get_complete_revision(device)
	local revision = device:get_revision()
	if revision then
		local prefix, suffix = revision:match("^(.+FAR%d+A%d+)(M4G.*)$")
		if prefix and suffix then
			local response = device:send_singleline_command('AT+CSUB', 'SubEdition:')
			if response then
				local sub_edition = response:match("^SubEdition: (V%d+)$")
				if sub_edition and sub_edition ~= "" then
					revision = prefix .. sub_edition .. suffix
				end
			end
		end
	end
	return revision
end

function Mapper:get_device_info(device, info) --luacheck: no unused args
	if not device.buffer.device_info.mode then
		device.buffer.device_info.mode = device:get_mode()
	end
	if device.buffer.device_info.mode == "upgrade" then
		if not device.buffer.device_info.software_version and device.buffer.firmware_upgrade_info then
			device.buffer.device_info.software_version = device.buffer.firmware_upgrade_info.old_version
		end
	else
		if not device.buffer.device_info.imei_svn then
			local ret = device:send_singleline_command("AT+EGMR=0,9", "+EGMR:")
			if ret then
				device.buffer.device_info.imei_svn = ret:match('%+EGMR:%s*"(%d%d)"')
			end
		end
		if not device.buffer.device_info.hardware_version then
			local ret = device:send_singleline_command("AT+QHVN?", "+QHVN:")
			if ret then
				device.buffer.device_info.hardware_version = ret:match('^+QHVN:%s?(.-)$')
			end
		end
		if not device.buffer.device_info.software_version then
			device.buffer.device_info.software_version = get_complete_revision(device)
		end
	end
end

local bandwidth_map = {
	['0'] = 1.4,
	['1'] = 3,
	['2'] = 5,
	['3'] = 10,
	['4'] = 15,
	['5'] = 20
}

function Mapper:get_radio_signal_info(device, info)
	local ret = device:send_singleline_command('AT+QNWINFO', "+QNWINFO:")
	if ret then
		info.radio_bearer_type = string.match(ret, '+QNWINFO:%s?"(.-)"')
	end
	ret = device:send_singleline_command('AT+QENG="servingcell"', "+QENG:")
	if ret then
		local act = string.match(ret, '+QENG:%s?"servingcell",".-","(.-)"')
		if act == 'LTE' then
			local phy_cell_id, earfcn, band, ul_bw, dl_bw, rsrp, rsrq, rssi, sinr, tx_power = string.match(ret, '+QENG:%s?"servingcell",".-","LTE",".-",%d+,%d+,%x+,(%d+),(%d+),(%d+),(%d+),(%d+),%x+,([%d-]+),([%d-]+),([%d-]+),([%d-]+),[%d-]+,([%d-]+)')
			info.lte_band = tonumber(band)
			info.lte_ul_bandwidth = bandwidth_map[ul_bw]
			info.lte_dl_bandwidth = bandwidth_map[dl_bw]
			info.rsrp = tonumber(rsrp)
			info.rsrq = tonumber(rsrq)
			info.rssi = tonumber(rssi)
			sinr = tonumber(sinr)
			if sinr then
				info.sinr = ((sinr/5)-20)
			end
			tx_power = tonumber(tx_power)
			if tx_power ~= -32768 then
				info.tx_power = tx_power/10
			end
			info.dl_earfcn = tonumber(earfcn)
			info.phy_cell_id = tonumber(phy_cell_id)
		elseif act == 'GSM' then
			local arfcn = string.match(ret, '+QENG:%s?"servingcell",".-","GSM",%d+,%d+,%x+,%x+,%d+,(%d+)')
			info.dl_arfcn = tonumber(arfcn)
		elseif act == 'WCDMA' then
			local uarfcn, rscp, ecio = string.match(ret, '+QENG:%s?"servingcell",".-","WCDMA",%d+,%d+,%x+,%x+,(%d+),%d+,%d+,([%d-]+),([%d-]+)')
			info.dl_uarfcn = tonumber(uarfcn)
			info.rscp = tonumber(rscp)
			info.ecio = tonumber(ecio)
		end
	end
end

local function get_supported_lte_bands(device)
	local supported_bands = {}
	local ret = device:send_singleline_command("AT+QNVR=6828,0", "+QNVR:")
	if ret then
		local data = string.match(ret, '+QNVR:%s?"(.-)"')
		if data then
			data = string.sub(data, 1, 16)
			local offset = 0
			for i = 1, #data, 2 do
				local byte = tonumber(data:sub(i, i + 1), 16)
				for b = 0, 7 do
					if bit.band(byte, bit.lshift(1, b)) ~= 0 then
						table.insert(supported_bands, b + offset + 1)
					end
				end
				offset = offset + 8
			end
		end
	end
	return supported_bands
end

function Mapper:get_device_capabilities(device, info)
	info.band_selection_support = "lte"
	info.cs_voice_support = true
	info.volte_support = true
	info.max_data_sessions = 8
	info.supported_auth_types = "none pap chap papchap"

	local ret = device:send_singleline_command("AT+QHVN?", "+QHVN:")
	if ret then
		local hardware_version = ret:match('^+QHVN:%s?(.-)$')
		if hardware_version and hardware_version:match("EC25AUTL") then
			info.cs_voice_support = false
			info.radio_interfaces = {
				{ radio_interface = "lte", supported_bands = get_supported_lte_bands(device) }
			}
			return
		end
	end

	local radio_interfaces = {}
	table.insert(radio_interfaces, { radio_interface = "auto" })
	table.insert(radio_interfaces, { radio_interface = "gsm" })
	table.insert(radio_interfaces, { radio_interface = "umts" })
	table.insert(radio_interfaces, { radio_interface = "lte", supported_bands = get_supported_lte_bands(device) })
	info.radio_interfaces = radio_interfaces
end

function Mapper:network_scan(device, start)
	if start and device.cops_command then
		-- Deregister from the network before starting the scan, otherwise it will fail.
		device:send_command("AT+COPS=2")
	end
end

local function get_gateway_info(key)
	local values = uci.cursor():get_all("env", "var") or {}
	return values[key]
end

local config_defaults = {
	audio_digital_tx_gain = { default = 8192, type = "number" },
	audio_codec_tx_gain = { default = 8192, type = "number" },
	audio_digital_rx_gain = { default = 8192, type = "number" },
	sip_user_agent = { default = 'Quectel <model> <software_version>', type = "string" },
	mbn_selection = { default = "none", type = "string" }
}

function Mapper:configure_device(device, config)
	for k, v in pairs(config_defaults) do
		if v.type == "number" then
			config.device[k] = tonumber(config.device[k])
		end
		if not config.device[k] then
			config.device[k] = v.default
		end
	end

	local reset_required = false
	local log = device.runtime.log

	local parsed_user_agent = config.device.sip_user_agent:gsub("<(.-)>+", function(key)
		if key:match("gateway_") then
			local gw_info = get_gateway_info(key:match("gateway_(.*)$"))
			if gw_info then
				return gw_info
			end
		elseif device.buffer.device_info[key] then
			return device.buffer.device_info[key]
		end
	end)

	log:info('Using SIP user agent "%s"', parsed_user_agent)
	device:send_command(string.format('AT+QIMSCFG="user_agent","%s"', parsed_user_agent))

	device:send_command(string.format('AT+QMIC=%d,%d', config.device.audio_codec_tx_gain, config.device.audio_digital_tx_gain))
	device:send_command(string.format('AT+QRXGAIN=%d', config.device.audio_digital_rx_gain))

	if config.device.mbn_selection ~= "none" then
		local auto_select = device:send_singleline_command('AT+QMBNCFG="AutoSel"', '+QMBNCFG:')
		if auto_select then
			auto_select = auto_select:match('^%+QMBNCFG:%s*"AutoSel",%s*([01])$')
		end
		if config.device.mbn_selection == "auto" then
			if auto_select ~= "1" then
				if device:send_command('AT+QMBNCFG="AutoSel",1') then
					device.runtime.log:notice("Enabled MBN auto-selection")
					reset_required = true
				else
					log:error("Failed to enable MBN auto-selection")
				end
			end
		else
			local mbn_name = config.device.mbn_selection:gsub('^manual:', '') -- Strip the (optional) prefix.
			if auto_select ~= "0" then
				if device:send_command('AT+QMBNCFG="AutoSel",0') and device:send_command(string.format('AT+QMBNCFG="Select","%s"', mbn_name)) then
					log:notice("Disabled MBN auto-selection and selected MBN '%s'", mbn_name)
					reset_required = true
				else
					log:error("Failed to disable MBN auto-selection and select MBN '%s'", mbn_name)
				end
			else
				local selected_mbn = device:send_singleline_command('AT+QMBNCFG="Select"', '+QMBNCFG:')
				if selected_mbn then
					selected_mbn = selected_mbn:match('^%+QMBNCFG:%s*"Select",%s*"?([^"]*)"?$')
				end
				if selected_mbn ~= mbn_name then
					if device:send_command(string.format('AT+QMBNCFG="Select","%s"', mbn_name)) then
						log:notice("Selected MBN '%s'", mbn_name)
						reset_required = true
					else
						log:error("Failed to select MBN '%s'", mbn_name)
					end
				end
			end
		end
	end

	local ret
	if config.platform and config.platform.voice_interfaces then
		local _, voice_interface = next(config.platform.voice_interfaces)
		if voice_interface and voice_interface.type == "pcm" and voice_interface.slot then
			local samplerate = 0
			if voice_interface.samplerate == 16000 then
				samplerate = 1
			end
			local qdai_config = string.format("1,1,0,4,0,%d,1,%d", samplerate, voice_interface.slot)
			ret = device:send_singleline_command('AT+QDAI?', "+QDAI:")
			if ret and ret:match('^+QDAI:%s?(.-)$') ~= qdai_config then
				ret = device:send_command(string.format('AT+QDAI=%s', qdai_config))
				if not ret then
					log:error("Failed to configure PCM channel")
				else
					log:info("Configured PCM channel")
					reset_required = true
				end
			end
		end
	end

	local ims_pdn_enable
	if config.device.volte_enabled then
		ims_pdn_enable = 1
		ret = device:send_command('AT+QCFG="volte_disable",0')
	else
		ims_pdn_enable = 2
		ret = device:send_command('AT+QCFG="volte_disable",1')
	end
	if not ret then
		log:error("Failed to configure VoLTE disable")
	end

	ret = device:send_singleline_command('AT+QCFG="ims"',"+QCFG:")
	if ret and tonumber(ret:match('^+QCFG:%s?"ims",(%d)')) ~= ims_pdn_enable then
		ret = device:send_command(string.format('AT+QCFG="ims",%d', ims_pdn_enable))
		if not ret then
			log:error("Failed to configure IMS PDN")
		else
			log:info("Configured IMS PDN")
			reset_required = true
		end
	end

	local sim_hotswap_enabled = false
	ret = device:send_singleline_command('AT+QSIMDET?', "+QSIMDET:")
	if ret and string.match(ret, '^+QSIMDET:%s?(%d),%d$') == '1' then
		sim_hotswap_enabled = true
	end
	if config.sim_hotswap and not sim_hotswap_enabled then
		-- Enable SIM hotswap events on low level GPIO transition
		device:send_command("AT+QSIMDET=1,0")
		reset_required = true
	elseif not config.sim_hotswap and sim_hotswap_enabled then
		-- Platform doesn't support SIM hotswap so disable it
		device:send_command("AT+QSIMDET=0,0")
		reset_required = true
	end

	local expected = '01'
	if not config.device.enable_thin_ui_cfg or config.device.enable_thin_ui_cfg == '1' then
		expected = '00'
	end

	-- Make sure that CFUN is set to 0 when the module is powered on.
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/Thin_UI/enable_thin_ui_cfg"', "+QNVFR:") ~= "+QNVFR: " .. expected then
		if device:send_command('AT+QNVFW="/nv/item_files/Thin_UI/enable_thin_ui_cfg",' .. expected) then
			log:info("Configured auto-attach")
			reset_required = true
		else
			log:error("Failed to configure auto-attach")
		end
	end

	-- Disable sending automatic PDN disconnect requests for unused PDNs.
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/data/3gpp/ps/remove_unused_pdn"', "+QNVFR:") ~= "+QNVFR: 00" then
		if device:send_command('AT+QNVFW="/nv/item_files/modem/data/3gpp/ps/remove_unused_pdn",00') then
			log:info("Disabled sending automatic PDN disconnect requests for unused PDNs")
			reset_required = true
		else
			log:error("Failed to disable sending automatic PDN disconnect requests for unused PDNs")
		end
	end

	-- Disable controlling the radio state using the GPIO.
	device:send_command('AT+QCFG="airplanecontrol",0')

	local mode = 0
	local lte_band_mask
	for _, radio in ipairs(config.network.radio_pref) do
		if radio.type == "auto" then
			mode = 63
			break
		elseif radio.type == "lte" then
			lte_band_mask = helper.get_lte_band_mask(radio.bands)
			mode = bit.bor(mode, 16)
		elseif radio.type == "umts" then
			mode = bit.bor(mode, 8, 32)
		elseif radio.type == "gsm" then
			mode = bit.bor(mode, 4)
		end
	end

	if lte_band_mask then
		lte_band_mask = string.format("%x", lte_band_mask)
	else
		lte_band_mask = "ffffffffff"
	end

	ret = device:send_singleline_command('AT+QCFG="band"', '+QCFG:')
	if ret then
		local current_lte_band_mask = ret:match('^+QCFG:%s?"band",.-,(.-),.-$')
		if current_lte_band_mask then
			current_lte_band_mask = current_lte_band_mask:gsub('0x', '')
			-- After setting the band mask to ffffffffff, EC25-AUTL reports the band mask back as ffbfffffff
			if current_lte_band_mask == "ffbfffffff" then
				current_lte_band_mask = "ffffffffff"
			end
			if current_lte_band_mask ~= lte_band_mask then
				ret = device:send_command(string.format('AT+QCFG="band",ffff,%s,3f,1', lte_band_mask))
				if not ret then
					return nil, "Failed to configure LTE bands"
				end
			end
		end
	end

	ret = device:send_command(string.format('AT+QCFG="nwscanmodeex",%d,1', mode))
	if not ret then
		return nil, "Failed to configure radio preference"
	end

	-- Enable CS network registration events
	if not device:send_command("AT+CREG=2") then
		-- Some handsets in tethered mode don't support CREG=2
		device:send_command("AT+CREG=1")
	end

	-- Enable PS network registration events
	if not device:send_command("AT+CGREG=2") then
		-- Some handsets in tethered mode don't support CGREG=2
		device:send_command("AT+CGREG=1")
	end

	-- Construct the COPS command but do not execute it yet. Executing the COPS
	-- command on Quectel modules before the SIM is unlocked will return OK but
	-- afterwards the CGATT command will fail until COPS=2 and COPS=0 are called
	-- again. This command however requires information from the network config so
	-- it is constructed here and stored for later use.
	if config.network then
		local cops_command = "AT+COPS=0,,"
		if config.network.selection_pref == "manual" and config.network.mcc and config.network.mnc then
			cops_command = 'AT+COPS=1,2,"' .. config.network.mcc .. config.network.mnc .. '"'
		end

		-- Take the highest priority radio
		local radio = config.network.radio_pref[1]
		if radio.type == "lte" then
			cops_command = cops_command .. ',7'
		elseif radio.type == "umts" then
			cops_command = cops_command .. ',2'
		elseif radio.type == "gsm" then
			cops_command = cops_command .. ',0'
		end

		device.cops_command = cops_command
		device:send_command(cops_command, 60000)
	end

	local roaming = 2
	if config.network.roaming == "none" then
		roaming = 1
	end
	ret = device:send_command(string.format('AT+QCFG="roamservice",%d,1', roaming))
	if not ret then
		return nil, "Failed to configure roaming"
	end

	if reset_required then
		-- Reset the device to apply the change
		device:send_command("AT+CFUN=1,1")
		return nil, "Module reset required"
	end

	return true
end

local function run_upgrade_script(device, script_name)
	local script_path = upgrade_dir .. "/" .. script_name
	if not lfs.attributes(script_path) then
		device.runtime.log:notice("Not executing %s: not present", script_name)
		return true
	end

	local script, errMsg = loadfile(script_path)
	if not script then
		local message = string.format("Failed to load %s: %s", script_name, errMsg)
		device.runtime.log:error(message)
		return nil, message
	end

	local sandbox = {
		-- Allow scripts calling all functions from these modules.
		math = math,
		string = string,
		table = table,
		uci = uci,

		-- Allow scripts calling these standard functions.
		assert = assert,
		error = error,
		getmetatable = getmetatable,
		ipairs = ipairs,
		next = next,
		pairs = pairs,
		pcall = pcall,
		rawequal = rawequal,
		rawget = rawget,
		rawset = rawset,
		setmetatable = setmetatable,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		unpack = unpack,
		xpcall = xpcall
	}

	function sandbox.print(...)
		local message = ""
		local separator = ""
		for _, argument in ipairs({...}) do
			message = message .. separator .. tostring(argument)
			separator = "\t"
		end
		device.runtime.log:notice("%s: %s", script_name, message)
	end

	function sandbox.upload_file(local_file, remote_file, timeout)
		if not timeout then
			timeout = 10
		end

		-- Make sure that only files inside the upgrade directory can be uploaded.
		if not local_file:match("^[%w_.-]+$") then
			local message = string.format("Invalid filename: %s", local_file)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end

		local file_source, err_msg = atchannel.file_source(upgrade_dir .. "/" .. local_file)
		if not file_source then
			local message = string.format("Could not read %s: %s", local_file, err_msg)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end

		local checksum_source
		checksum_source, err_msg = atchannel.checksum_source(file_source)
		if not checksum_source then
			local message = string.format("Could not calculate checksum of %s: %s", local_file, err_msg)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end

		-- Upload the file to the flash of the module.
		local upload_command = string.format('AT+QFUPL="%s",%d,%d', remote_file, file_source.size, timeout)
		local upload_result
		upload_result, err_msg = device:send_singleline_command_with_source(upload_command, '+QFUPL:', timeout * 1000, checksum_source)
		if not upload_result then
			local message = string.format("Could not upload %s to %s: %s", local_file, remote_file, err_msg)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end

		-- Verify that the file was successfully uploaded.
		local size, checksum = upload_result:match("^%s*%+QFUPL:%s*(%d+)%s*,%s*(%x+)%s*$")
		if not checksum then
			local message = string.format("Failed to upload %s to %s", local_file, remote_file)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end
		if tonumber(size, 10) ~= file_source.size then
			local message = string.format("Size of %s not equal to size of %s", local_file, remote_file)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end
		if tonumber(checksum, 16) ~= checksum_source.checksum then
			local message = string.format("Checksum of %s does not match checksum of %s", local_file, remote_file)
			device.runtime.log:error("%s: %s", script_name, message)
			return nil, message
		end

		return true
	end

	function sandbox.at_command(command)
		return device:send_command(command)
	end

	function sandbox.singleline_at_command(command, prefix)
		return device:send_singleline_command(command, prefix)
	end

	function sandbox.multiline_at_command(command, prefix)
		return device:send_multiline_command(command, prefix)
	end

	function sandbox.reload_mobiled_config()
		device.runtime.mobiled.reloadconfig()
	end

	local success
	success, errMsg = pcall(setfenv(script, sandbox))
	if not success then
		local message = string.format("Failed to execute %s: %s", script_name, errMsg)
		device.runtime.log:error(message)
		return nil, message
	end

	return true
end

function Mapper:init_device(device)
	if device:get_mode() == "upgrade" then
		local info = firmware_upgrade.get_state()
		if info and (info.status == "started" or info.status == "downloading" or info.status == "downloaded" or info.status == "flashing") then
			device.buffer.firmware_upgrade_info = info
		else
			device.buffer.firmware_upgrade_info = { status = "flashing" }
			firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
		end
	else
		-- the Thin_UI option will set CFUN=0 on power on, set it to 4 to prevent that certain AT commands will not work.
		if device:send_singleline_command('AT+CFUN?', '+CFUN:') == '+CFUN: 0' then
			device:send_command('AT+CFUN=4')
		end

		-- Enable NITZ events
		device:send_command("AT+CTZR=2")
		-- Enable packet domain events
		device:send_command("AT+CGEREP=2,1")
		-- Enable RmNet device status events
		device:send_command("AT+QNETDEVSTATUS=1")
		-- Enable voice call state change eventing
		device:send_command("AT^DSCI=1")
		-- Enable Distinctive Ring Information and RTP Stream Detection Information
		device:send_command("AT+QTELSTRASUP=1,1")

		-- Check whether this is the first boot after a firmware upgrade, check whether it has succeeded and send out the appropriate event.
		local info = firmware_upgrade.get_state()
		if info and (info.status == "started" or info.status == "downloading" or info.status == "downloaded" or info.status == "flashing") then
			local current_revision = get_complete_revision(device)
			if current_revision and current_revision ~= info.old_version and run_upgrade_script(device, "postflash_commands.lua") then
				info.status = "done"
				device:send_event("mobiled", { event = "firmware_upgrade_done", dev_idx = device.dev_idx })
			else
				info.status = "failed"
				info.error_code = firmware_upgrade.error_codes.flashing_failed
				device:send_event("mobiled", { event = "firmware_upgrade_failed", dev_idx = device.dev_idx })
			end
			device.buffer.firmware_upgrade_info = info
		else
			device.buffer.firmware_upgrade_info = { status = "not_running" }
		end
		firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
		os.execute(string.format("rm -rf '%s'", upgrade_dir))

		if device.network_interfaces then
			for _, interface in pairs(device.network_interfaces) do
				os.execute(string.format("[ -f /sys/class/net/%s/qmi/raw_ip ] && echo Y > /sys/class/net/%s/qmi/raw_ip", interface, interface))
			end
		end
	end

	return true
end

-- AT+CFUN=0 will disable the SIM on Quectel modules causing mobiled not to be
-- able to initialise the SIM anymore.  Therefore CFUN=4 is used in both the
-- lowpower and airplane power modes.
function Mapper:set_power_mode(device, mode)
	if mode == "lowpower" or mode == "airplane" then
		device.buffer.session_info = {}
		device.buffer.network_info = {}
		device.buffer.radio_signal_info = {}
		return device:send_command('AT+CFUN=4', 5000)
	end
	return device:send_command('AT+CFUN=1', 5000)
end

local function send_firmware_upgrade_failed(device, error_code)
	device.buffer.firmware_upgrade_info.status = "failed"
	device.buffer.firmware_upgrade_info.error_code = error_code
	firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
	device:send_event("mobiled", { event = "firmware_upgrade_failed", dev_idx = device.dev_idx })
end

local function start_firmware_upgrade(device)
	if device.firmware_upload.exit_status == 0 then
		-- Make sure no voice calls are ongoing.
		if not device.calls or not next(device.calls) then
			if run_upgrade_script(device, "preflash_commands.lua") then
				-- The Quectel module will immediately reboot after the AT+QFOTADL command has
				-- been issued so make sure to save the state before running the command.
				firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)

				if not device:send_command(string.format('AT+QFOTADL="/data/ufs/%s"', device.firmware_upload.filename)) then
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.flashing_failed)
				end
			else
				send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.flashing_failed)
			end
		else
			send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.invalid_state)
		end
	else
		send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.invalid_image)
	end
end

local function handle_download_finished(device)
	return function(exit_status)
		if device.firmware_upload then
			device.firmware_upload.exit_status = exit_status

			if device.firmware_upload.file_size then
				start_firmware_upgrade(device)
				device.firmware_upgrade = nil
			end
		end
	end
end

local function cleanup_firmware_upgrade(device, file_handle, temp_dir, error_code)
	if file_handle then
		device:send_command(string.format('AT+QFCLOSE=%s', file_handle))
	end

	if temp_dir then
		os.execute(string.format("/bin/rm -rf '%s'", temp_dir))
	end

	send_firmware_upgrade_failed(device, error_code)
end

function Mapper:firmware_upgrade(device, path)
	local filename = "upgrade.zip"
	local buffer_size = 2 * 1024 * 1024
	local chunk_size = 64 * 1024

	if not path then
		device.buffer.firmware_upgrade_info.status = "invalid_parameters"
		return nil, "Invalid parameters"
	end

	local current_revision = get_complete_revision(device)
	if not current_revision then
		cleanup_firmware_upgrade(device, nil, nil, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to determine current revision"
	end
	device.buffer.firmware_upgrade_info.old_version = current_revision

	-- Remove the image from the previous attempt (if there is any).
	if device.firmware_upload then
		device:send_command(string.format('AT+QFCLOSE=%s', device.firmware_upload.file_handle))
	end
	device:send_command(string.format('AT+QFDEL="%s"', filename))

	-- Open the file for reading and writing, creating it if it does not exist.
	local open_result = device:send_singleline_command(string.format('AT+QFOPEN="%s",1', filename), '+QFOPEN:')
	if not open_result then
		cleanup_firmware_upgrade(device, nil, nil, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to open file"
	end
	local file_handle = string.match(open_result, '%+QFOPEN:%s*(%d+)')
	if not file_handle then
		cleanup_firmware_upgrade(device, nil, nil, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to open file"
	end

	-- Make sure all files related to a previous upgrade attempt are removed.
	os.execute(string.format("rm -rf '%s'", upgrade_dir))

	-- Create a temporary pipe through which the image is transfered.
	local mktemp_process = io.popen("/bin/mktemp -d")
	if not mktemp_process then
		cleanup_firmware_upgrade(device, file_handle, nil, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to create temporary directory"
	end
	local temp_dir = mktemp_process:read("*line")
	mktemp_process:close()
	if not temp_dir then
		cleanup_firmware_upgrade(device, file_handle, nil, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to create temporary directory"
	end
	local fifo_path = string.format("%s/output_fifo", temp_dir)
	if os.execute(string.format("/usr/bin/mkfifo '%s'", fifo_path)) ~= 0 then
		cleanup_firmware_upgrade(device, file_handle, temp_dir, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to create pipe"
	end

	-- Start the process that downloads the image.
	local download_process = uloop.process("/usr/lib/sysupgrade-tch/check_mobiled_bli.sh", {upgrade_dir, temp_dir, path, current_revision}, {}, handle_download_finished(device))
	if not download_process then
		cleanup_firmware_upgrade(device, file_handle, temp_dir, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to create pipe"
	end

	-- Create a data source that reads from the pipe. Make sure to do this after the process is spawned, otherwise a deadlock will occur.
	local file_source = atchannel.file_source(fifo_path, true)
	if not file_source then
		cleanup_firmware_upgrade(device, file_handle, temp_dir, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to download firmware"
	end
	local async_source = atchannel.async_source(file_source, device:get_interface().port, buffer_size, chunk_size)
	if not async_source then
		cleanup_firmware_upgrade(device, file_handle, temp_dir, firmware_upgrade.error_codes.download_failed)
		return nil, "Unable to download firmware"
	end

	device.firmware_upload = {
		filename = filename,
		file_handle = file_handle,
		download_process = download_process,
		file_source = file_source,
		async_source = async_source
	}

	device.buffer.firmware_upgrade_info.status = "started"
	firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
	return true
end

function Mapper:get_firmware_upgrade_info(device)
	return device.buffer.firmware_upgrade_info
end

local function convert_time(datetime, tz, dst)
	local daylight_saving_time = tonumber(dst)
	local timezone = tonumber(tz) * 15
	local localtime
	local year, month, day, hour, min, sec = string.match(datetime, "(%d+)/(%d+)/(%d+),(%d+):(%d+):(%d+)")
	if year then
		localtime = os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec})
		return localtime, timezone, daylight_saving_time
	end
end

local function send_call_disconnect_event(device, call)
	device:send_event("mobiled.voice", {
		event = "call_state_changed",
		call_id = call.mmpbx_call_id,
		dev_idx = device.dev_idx,
		call_state = call.call_state,
		reason = call.release_reason,
		remote_party = call.remote_party,
		number_format = call.number_format
	})
	return true
end

local dsci_call_states = {
	-- held
	["1"] = {
		call_state = "connected",
		media_state = "held"
	},
	-- originated
	["2"] = {
		call_state = "dialing",
		media_state = "no_media"
	},
	-- connect
	["3"] = {
		call_state = "connected",
		media_state = "normal"
	},
	-- incoming
	["4"] = {
		call_state = "alerting",
		media_state = "no_media"
	},
	-- waiting
	["5"] = {
		call_state = "alerting",
		media_state = "no_media"
	},
	-- end
	["6"] = {
		call_state = "disconnected",
		media_state = "normal"
	},
	-- alerting
	["7"] = {
		call_state = "delivered",
		media_state = "normal"
	}
}

function Mapper:unsolicited(device, data, sms_data) --luacheck: no unused args
	local prefix, message = data:match('^(%p[%u%s]+):%s*(.*)$')
	if prefix == "+CTZE" then
		local tz, dst, datetime = message:match('^"([+0-9]+)",(%d),"(.-)"$')
		if datetime then
			local localtime, timezone, daylight_saving_time = convert_time(datetime, tz, dst)
			local event_data = {
				event = "time_update_received",
				daylight_saving_time = daylight_saving_time,
				localtime = localtime,
				timezone = timezone,
				dev_idx = device.dev_idx
			}
			device:send_event("mobiled", event_data)
		end
		return true
	elseif prefix == "+QNWLOCK" or prefix == "+QUSIM" or prefix == "+CGEV" then
		return true
	elseif prefix == "+QIND" then
		if message == "SMS DONE" or message == "PB DONE" then
			return true
		end
		local qind_command, qind_arguments = message:match('^"([^"]+)",?%s*(.*)$')
		if qind_command == "FOTA" then
			local fota_command, fota_arguments = qind_arguments:match('^"(%u+)",?%s*(.*)$')
			if fota_command == "FTPSTART" then
				device.buffer.firmware_upgrade_info.status = "downloading"
			elseif fota_command == "FTPEND" then
				local ftp_error = tonumber(fota_arguments)
				if ftp_error == 0 then
					device.buffer.firmware_upgrade_info.status = "downloaded"
				else
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				end
			elseif fota_command == "HTTPSTART" then
				device.buffer.firmware_upgrade_info.status = "downloading"
			elseif fota_command == "HTTPEND" then
				local http_error = tonumber(fota_arguments)
				if http_error == 0 then
					device.buffer.firmware_upgrade_info.status = "downloaded"
				else
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				end
			elseif fota_command == "START" then
				device.buffer.firmware_upgrade_info.status = "flashing"
			elseif fota_command == "UPDATING" then
				local progress = tonumber(fota_arguments)
				if progress then
					device.buffer.firmware_upgrade_info.status = "flashing"
				end
			elseif fota_command == "END" then
				local error_code = tonumber(fota_arguments)
				if error_code ~= 0 then
					-- Do not send out done events as the postflash commands still have to run.
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				end
			end
			firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
			return true
		end
	elseif prefix == "^DSCI" then
		local call_id, direction, call_state, mode, remote_party, number_type = message:match('(%d+),(%d+),(%d+),(%d+),(.-),(%d+)')
		call_id = tonumber(call_id)
		if call_id and voice.clcc_mode[mode] == "voice" then
			local current_dsci_call_state = dsci_call_states[call_state].call_state
			device.calls[call_id] = device.calls[call_id] or {}
			device.calls[call_id].remote_party = remote_party
			device.calls[call_id].direction = voice.clcc_direction[direction]
			device.calls[call_id].number_format = voice.clcc_number_type[number_type]

			if current_dsci_call_state == "disconnected" then
				if device.conference and device.conference.mmpbx_call_id == device.calls[call_id].mmpbx_call_id then
					device.calls[call_id] = nil

					local conference_ongoing = false
					local call_id_in_use = false
					local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
					if ret then
						for _, clcc_call_info in pairs(ret) do
							local id, call_state, mode, conference_state, phone_number = string.match(clcc_call_info, '^%+CLCC:%s*(%d+),%d+,(%d+),(%d+),(%d+),"(.-)",%d+$')
							id = tonumber(id)
							if id and voice.clcc_mode[mode] == "voice" and device.calls[id] then
								conference_ongoing = conference_ongoing or conference_state == "1" or phone_number == "sip:mmtel"
								call_id_in_use = call_id_in_use or device.calls[id].mmpbx_call_id == device.conference.mmpbx_call_id
							end
						end
					end
					if not conference_ongoing then
						if not call_id_in_use then
							device:send_event("mobiled.voice", {
								event = "call_state_changed",
								call_id = device.conference.mmpbx_call_id,
								dev_idx = device.dev_idx,
								call_state = "disconnected",
								reason = "normal",
								remote_party = remote_party,
								number_format = voice.clcc_number_type[number_type]
							})
						end

						device.conference = nil
					end
				else
					if device.calls[call_id].call_state ~= "disconnected" then
						device.calls[call_id].release_reason = "normal"
						device.calls[call_id].call_state = current_dsci_call_state
						send_call_disconnect_event(device, device.calls[call_id])
					end
					device.calls[call_id] = nil
				end
			elseif current_dsci_call_state == "dialing" or current_dsci_call_state == "alerting" then
				device.calls[call_id].call_state = current_dsci_call_state
				device.calls[call_id].media_state = dsci_call_states[call_state].media_state
				if not device.calls[call_id].mmpbx_call_id then -- occurs in case of call state alerting
					if device.conference and remote_party == "sip:mmtel" then
						device.calls[call_id].mmpbx_call_id = device.conference.mmpbx_call_id
					else
						device.calls[call_id].mmpbx_call_id = device.mmpbx_call_id_counter
						device.mmpbx_call_id_counter = device.mmpbx_call_id_counter + 1
					end
				end
				if not device.conference or device.calls[call_id].mmpbx_call_id ~= device.conference.mmpbx_call_id then
					local event = {
						event = "call_state_changed",
						call_id = device.calls[call_id].mmpbx_call_id,
						dev_idx = device.dev_idx,
						call_state = device.calls[call_id].call_state,
						reason = device.calls[call_id].release_reason,
						remote_party = remote_party,
						number_format = device.calls[call_id].number_format
					}
					if current_dsci_call_state == "alerting" and device.distinctive_ring then
						event.distinctive_ring = device.distinctive_ring
						device.distinctive_ring = nil
					end
					device:send_event("mobiled.voice", event)
				end
			else -- call state = connected or delivered
				if device.calls[call_id].call_state ~= current_dsci_call_state then
					if not device.conference or device.calls[call_id].mmpbx_call_id ~= device.conference.mmpbx_call_id then
						if current_dsci_call_state == "connected" and device.calls[call_id].call_state == "dialing" then
							device:send_event("mobiled.voice", {
								event = "call_state_changed",
								call_id = device.calls[call_id].mmpbx_call_id,
								dev_idx = device.dev_idx,
								call_state = "delivered",
								reason = device.calls[call_id].release_reason,
								remote_party = remote_party,
								number_format = device.calls[call_id].number_format
							})
						end
						device:send_event("mobiled.voice", {
							event = "call_state_changed",
							call_id = device.calls[call_id].mmpbx_call_id,
							dev_idx = device.dev_idx,
							call_state = current_dsci_call_state,
							reason = device.calls[call_id].release_reason,
							remote_party = remote_party,
							number_format = device.calls[call_id].number_format
						})
					end
					device.calls[call_id].call_state = current_dsci_call_state
					device.calls[call_id].media_state = dsci_call_states[call_state].media_state
				end
			end
		end
		return true
	elseif prefix == "+ESM ERROR" or prefix == "+EMM ERROR" then
		local cid, reject_cause = message:match("^(%d+),(%d+)$")
		if cid then
			device:send_event("mobiled", {
				event = "session_disconnected",
				dev_idx = device.dev_idx,
				reject_cause = tonumber(reject_cause),
				session_id = tonumber(cid) - 1
			})
		end
		return true
	elseif prefix == "+MWI" then
		local msg_type, msg_count = message:match("^([0-4])%s*,%s*[01]%s*,%s*([0-9]+)$")
		-- Check whether the match was successful and the message type is VOICE.
		if msg_type == "0" then
			device.buffer.voice_info.messages_waiting = tonumber(msg_count)
			device:send_event("mobiled.voice", {
				dev_idx = device.dev_idx,
				event = "messages_waiting",
				messages_waiting = device.buffer.voice_info.messages_waiting
			})
		end
		return true
	elseif prefix == "+RTPDI" then
		for _, call in pairs(device.calls) do
			if call.call_state == "dialing" or call.call_state == "delivered" then
				device:send_event("mobiled.voice", {
					dev_idx = device.dev_idx,
					call_id = call.mmpbx_call_id,
					event = "early_media",
					early_media = message == "1"
				})
				break
			end
		end
		return true
	elseif prefix == "+DRI" then
		device.distinctive_ring = tonumber(message)
		return true
	end
end

function Mapper:get_time_info(device, info)
	local ret = device:send_singleline_command("AT+QLTS=2", "+QLTS:")
	if ret then
		local datetime, tz, dst = string.match(ret, '^+QLTS:%s?"([%d/,:]+)([%+%-%d]+),(%d)"')
		info.localtime, info.timezone, info.daylight_saving_time = convert_time(datetime, tz, dst)
		return true
	end
end

function Mapper:set_attach_params(device, profile)
	local pdptype, errMsg = session_helper.get_pdp_type(device, profile.pdptype)
	if not pdptype then
		return nil, errMsg
	end
	local apn = profile.apn or ""
	local authtype, username, password = get_auth_parameters(profile)
	device:send_command("AT+COPS=2")
	if not device:send_command(string.format('AT+QICSGP=1,1,"%s","%s","%s",%s', apn, username, password, authtype)) then
		return nil, "Failed to set authentication parameters"
	end
	if not device:send_command(string.format('AT+CGDCONT=1,"%s","%s"', pdptype, apn)) then
		return nil, "Failed to set attach parameters"
	end
	if device.cops_command then
		device:send_command(device.cops_command, 60000)
	end

	return true
end

function Mapper:network_attach(device)
	if device.attach_pending then
		return true
	end

	if not device:start_command('AT+CGATT=1', 150000) then
		return nil, "Failed to attach"
	end

	device.attach_pending = true
	return true
end

function Mapper:handle_event(device, message)
	if message.event == "command_finished" then
		if message.command == "AT+CGATT=1" then
			if not device:poll_command() then
				device.runtime.log:notice("Attach failed")
			end
			device.attach_pending = false
		end
	elseif message.event == "command_cleared" then
		if message.command == "AT+CGATT=1" then
			device.attach_pending = false
		end
	elseif message.event == "async_chunk_received" then
		if device.firmware_upload then
			local write_timeout = 2 -- s
			local limited_source = atchannel.limited_source(device.firmware_upload.async_source, message.num_bytes)
			if limited_source then
				local write_command = string.format('AT+QFWRITE=%s,%d,%d', device.firmware_upload.file_handle, message.num_bytes, write_timeout)
				local write_result = device:send_singleline_command_with_source(write_command, '+QFWRITE:', write_timeout * 1000, limited_source)
				if not write_result or tonumber(write_result:match('%+QFWRITE:%s*(%d+)%s*,%s*%d+')) ~= message.num_bytes then
					device:send_command(string.format('AT+QFCLOSE=%s', device.firmware_upload.file_handle))
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
					device.firmware_upload = nil
				end
			else
				device:send_command(string.format('AT+QFCLOSE=%s', device.firmware_upload.file_handle))
				send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				device.firmware_upload = nil
			end
		end
	elseif message.event == "async_end_of_file" then
		if device.firmware_upload then
			if device:send_command(string.format('AT+QFCLOSE=%s', device.firmware_upload.file_handle), '+QFCLOSE:') then
				local file_info = device:send_singleline_command(string.format('AT+QFLST="%s"', device.firmware_upload.filename), '+QFLST:')
				if file_info then
					local file_size = tonumber(file_info:match('%+QFLST:%s*"[^"]*"%s*,%s*(%d+)'))
					if file_size then
						device.firmware_upload.file_size = file_size

						-- Do not set device.firmware_upload to nil if the process is still running.
						if not device.firmware_upload.exit_status then
							return
						end

						start_firmware_upgrade(device)
					else
						send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
					end
				else
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				end
			else
				send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
			end

			device.firmware_upload = nil
		end
	end
end

function Mapper:destroy_device(device, force) --luacheck: no unused args
	 if device.calls then
		if device.conference then
			local disconnect_event_sent = false
			for call_id, call in pairs(device.calls) do
				if call.mmpbx_call_id == device.conference.mmpbx_call_id then
					if not disconnect_event_sent then
						call.release_reason = "device_disconnected"
						call.call_state = "disconnected"
						send_call_disconnect_event(device, call)
						disconnect_event_sent = true
					end
					device.calls[call_id] = nil
				end
			end
			device.conference = nil
		end
		for call_id, call in pairs(device.calls) do
			call.release_reason = "device_disconnected"
			call.call_state = "disconnected"
			send_call_disconnect_event(device, call)
		end
		device.calls = nil
	end
	device.runtime.log:info("Closing Quectel UBUS")
	device.ubus:close()
end

local function link_changed(device, msg)
	local i = 0
	for _, interface in pairs(device.network_interfaces) do
		if msg and msg.interface == interface then
			-- Workaround for RAW-IP interfaces not having a link-local IPv6 address because of missing MAC
			os.execute(string.format("ip address add dev %s scope link fe80::20:ff:fe00:%d/64", interface, i))
		end
		i = i + 1
	end
end

function Mapper:end_call(device, mmpbx_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	if device.conference and device.conference.mmpbx_call_id == mmpbx_call_id then
		local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
		if not ret then
			return nil, "Could not retrieve call info"
		end
		for _, clcc_call_info in pairs(ret) do
			local id, mode, conference_state, phone_number = string.match(clcc_call_info, '^%+CLCC:%s*(%d+),%d+,%d+,(%d+),(%d+),"(.-)",%d+$')
			id = tonumber(id)
			if id and voice.clcc_mode[mode] == "voice" and (conference_state == "1" or phone_number == "sip:mmtel") then
				device:send_command(string.format('AT+CHLD=1%d', id), 5000)
			end
		end
		return true
	end

	for call_id, call in pairs(device.calls) do
		if call.mmpbx_call_id == mmpbx_call_id then
			device:send_command(string.format('AT+CHLD=1%d', call_id), 5000)
			return true
		end
	end
	return nil, "Unknown call ID"
end

function Mapper:accept_call(device, mmpbx_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	for _, call in pairs(device.calls) do
		if call.mmpbx_call_id == mmpbx_call_id then
			if call.call_state ~= "alerting" then
				return nil, "Call in invalid state"
			end

			return device:send_command(string.format('AT+CHLD=2'), 5000)
		end
	end
	return nil, "Unknown call ID"
end

function Mapper:multi_call(device, mmpbx_call_id, action, mmpbx_second_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	if action == "hold_call" or action == "resume_call" then
		if device.conference and device.conference.mmpbx_call_id == mmpbx_call_id then
			if action == "hold_call" and device.conference.media_state == "normal" then
				device:send_command(string.format('AT+CHLD=2'), 5000)
				device.conference.media_state = "held"
			elseif action == "resume_call" and  device.conference.media_state == "held" then
				device:send_command(string.format('AT+CHLD=3'), 5000)
				device.conference.media_state = "normal"
			end
			device:send_event("mobiled.voice", {
				event = "media_state_changed",
				call_id = mmpbx_call_id,
				dev_idx = device.dev_idx,
				media_state = device.conference.media_state
			})
			return true
		end

		for _, call in pairs(device.calls) do
			if call.mmpbx_call_id == mmpbx_call_id then
				if (action ~= "hold_call" or call.media_state ~= "normal") and (action ~= "resume_call" or call.media_state ~= "held") then
					return nil, "Call in invalid state"
				end

				device:send_command(string.format('AT+CHLD=2'), 5000)

				-- Because the "AT+CHLD=2" can change the call and media states of multiple calls,
				-- we need to loop over the return values of "AT+CLCC" and set the correct call and media states,
				-- and send the correct events to MMPBX.
				local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
				if not ret then
					return nil, "Could not retrieve call info"
				end
				for _, clcc_call_info in pairs(ret) do
					local id, call_state, mode, conference_state, phone_number = string.match(clcc_call_info, '%+CLCC:%s*(%d+),%d+,(%d+),(%d+),(%d+),"(.-)",%d+')
					id = tonumber(id)
					if id and voice.clcc_mode[mode] == "voice" then
						if conference_state ~= "1" and phone_number ~= "sip:mmtel" then
							if device.calls[id].call_state ~= voice.clcc_call_states[call_state].call_state then
								device.calls[id].call_state = voice.clcc_call_states[call_state].call_state
								device:send_event("mobiled.voice", {
									event = "call_state_changed",
									call_id = device.calls[id].mmpbx_call_id,
									dev_idx = device.dev_idx,
									call_state = device.calls[id].call_state,
									reason = device.calls[id].release_reason,
									remote_party = device.calls[id].remote_party,
									number_format = device.calls[id].number_format
								})
							elseif device.calls[id].media_state ~= voice.clcc_call_states[call_state].media_state then
								device.calls[id].media_state = voice.clcc_call_states[call_state].media_state
								device:send_event("mobiled.voice", {
									event = "media_state_changed",
									call_id = device.calls[id].mmpbx_call_id,
									dev_idx = device.dev_idx,
									media_state = device.calls[id].media_state
								})
							end
						end
						device.calls[id].call_state = voice.clcc_call_states[call_state].call_state
						device.calls[id].media_state = voice.clcc_call_states[call_state].media_state
					end
				end
				return true
			end
		end
		return nil, "Unknown call ID"
	elseif action == "conf_call" then
		mmpbx_second_call_id = tonumber(mmpbx_second_call_id)
		if not mmpbx_second_call_id then
			return "Invalid second call ID"
		end

		device:send_command(string.format('AT+CHLD=3'), 5000)

		device.conference = device.conference or {}
		device.conference.mmpbx_call_id = mmpbx_call_id
		device.conference.media_state = "normal"

		for call_id, call in pairs(device.calls) do
			if call.mmpbx_call_id == mmpbx_call_id then
				-- Mark the call as in conference to prevent an event to be sent when a DSCI URC
				-- is received. Make sure not to send a disconnect event as the call ID is
				-- reused for the conference call.
				call.release_reason = "normal"
				call.call_state = "disconnected"
			elseif call.mmpbx_call_id == mmpbx_second_call_id then
				call.release_reason = "normal"
				call.call_state = "disconnected"
				send_call_disconnect_event(device, call)
			end
		end

		device:send_event("mobiled.voice", {
			event = "media_state_changed",
			call_id = device.conference.mmpbx_call_id,
			dev_idx = device.dev_idx,
			media_state = device.conference.media_state
		})

		-- Update the states of the calls that are in conference.
		local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
		if not ret then
			return nil, "Could not retrieve call info"
		end
		for _, clcc_call_info in pairs(ret) do
			local id, call_state, mode, conference_state, phone_number = string.match(clcc_call_info, '^%+CLCC:%s*(%d+),%d+,(%d+),(%d+),(%d+),"(.-)",%d+$')
			id = tonumber(id)
			if id and voice.clcc_mode[mode] == "voice" and (conference_state == "1" or phone_number == "sip:mmtel") then
				device.calls[id] = device.calls[id] or {}
				device.calls[id].mmpbx_call_id = mmpbx_call_id
				device.calls[id].call_state = voice.clcc_call_states[call_state].call_state
				device.calls[id].media_state = voice.clcc_call_states[call_state].media_state
			end
		end

		return true
	end
	return nil, "Unsupported action"
end

function Mapper:get_network_interface(device, session_id)
	local session = device.sessions[session_id + 1]
	if session then
		return session.interface
	end
end

function Mapper:add_data_session(device, session)
	local cid = session.session_id + 1
	if not device.sessions[cid] then
		device.sessions[cid] = session
		if not session.internal and not session.proto then
			local host_interface
			if session.session_id == 0 then
				host_interface = table.remove(device.host_interfaces.eth, 1)
			else
				host_interface = table.remove(device.host_interfaces.ppp, 1)
			end
			if host_interface then
				session.proto = host_interface.proto
				session.interface = host_interface.interface
				device.runtime.log:error("Using %s for session %d", session.proto, session.session_id)
			else
				device.runtime.log:error("No more host interfaces available")
			end
		elseif session.internal then
			session.proto = "none"
		end
	end
	return true
end

local function get_emergency_numbers(device)
	local numbers = {}
	local ret = device:send_singleline_command("AT+QECCNUM=0,0", "+QECCNUM:")
	if ret then
		local num = ret:match("^+QECCNUM:%s?%d,(.-)$")
		if num then
			for number in num:gmatch('([^,"]+)') do
				table.insert(numbers, number)
			end
		end
	end
	return numbers
end

function Mapper:get_voice_info(device, info)
	info.emergency_numbers = get_emergency_numbers(device)
	if not info.volte then
		info.volte = {}
	end
	info.volte.registration_status = "not_registered"
	local ret = device:send_singleline_command('AT+QCFG="ims"', '+QCFG:')
	if ret then
	        local act = ret:match('^+QCFG:%s?"ims",%d,(%d)')
		if act == '1' then
			info.volte.registration_status = "registered"
		end
		return true
	end
end

function Mapper:set_emergency_numbers(device, numbers)
	local current_numbers = get_emergency_numbers(device, false)
	for _, number in pairs(current_numbers) do
		if number ~= "911" and number ~= "112" then
			device:send_command(string.format('AT+QECCNUM=2,0,"%s"', number))
			device:send_command(string.format('AT+QECCNUM=2,1,"%s"', number))
		end
	end
	for _, number in pairs(numbers) do
		device:send_command(string.format('AT+QECCNUM=1,0,"%s"', number))
		device:send_command(string.format('AT+QECCNUM=1,1,"%s"', number))
	end
end

local Interface = {}
Interface.__index = Interface

function Interface:open(tracelevel)
	local max_opens = 2 -- try not to reopen the channel too much in order to not loose unsolicited messages
	local max_probes = 20 -- probe a lot with short intervals so unsolicited messages are checked regularly
	local probe_timeout = 1000 -- ms

	local port = self.port
	local log = self.runtime.log

	for _ = 1, max_opens do
		log:notice("Opening " .. port)
		local channel = atchannel.open(port)
		if channel then
			atchannel.set_tracelevel(channel, tracelevel)
			self.buffered_messages = {} --  discard previously received gibberish

			for _ = 1, max_probes do
				if atchannel.send_command(channel, "AT", probe_timeout) then
					log:notice("Using AT channel " .. port)
					self.channel = channel
					self.mode = "normal"

					-- Disable echo and enable verbose result codes
					atchannel.send_command(channel, "ATE0Q0V1")

					-- Disable auto-answer
					atchannel.send_command(channel, "ATS0=0")

					-- Enable extended errors
					atchannel.send_command(channel, "AT+CMEE=1")

					return true
				end

				local upgrading = false
				for _, message in ipairs(atchannel.unsolicited(channel) or {}) do
					table.insert(self.buffered_messages, message)
					if not upgrading and message.at then
						upgrading = message.at:match('^%+QIND:%s*"FOTA"')
					end
				end
				if upgrading then
					log:notice("Using AT channel in upgrade mode " .. port)
					self.channel = channel
					self.mode = "upgrade"
					return true
				end
			end
		end
	end
	return nil, "Failed to open " .. port
end

function Interface:is_available()
	return self.mode == "normal" and atchannel.running(self.channel)
end

function Interface:is_busy()
	return not self:is_available() or atchannel.is_busy(self.channel)
end

function Interface:get_unsolicited_messages()
	local ret = {}
	for _, messages in ipairs({self.buffered_messages, atchannel.unsolicited(self.channel)}) do
		for _, message in ipairs(messages) do
			table.insert(ret, message)
		end
	end
	self.buffered_messages = {}
	return ret
end

function Interface:close()
	if self.channel then
		self.runtime.log:info("Closing " .. self.port)
		atchannel.close(self.channel)
		self.channel = nil
	end
end

function Interface:probe()
	return self:is_available()
end

function Interface:set_tracelevel(level)
	if self.channel then
		atchannel.set_tracelevel(self.channel, level)
	end
end

function M.create_interface(runtime, port)
	local interface = {
		port = port,
		runtime = runtime
	}
	setmetatable(interface, Interface)
	return interface
end

function M.create(runtime, device) --luacheck: no unused args
	local mapper = {
		mappings = {
			get_session_info = "augment",
			get_device_info = "runfirst", -- Make sure the fields are not yet set by the generic function
			start_data_session = "override",
			stop_data_session = "override",
			firmware_upgrade = "override",
			get_firmware_upgrade_info = "override",
			network_scan = "runfirst",
			configure_device = "override",
			set_power_mode = "override",
			set_attach_params = "override",
			network_attach = "override",
			handle_event = "override",
			end_call = "override",
			accept_call = "override",
			multi_call = "override"
		}
	}

	-- Sessions will be filled dynamically
	device.sessions = {}

	device.default_interface_type = "control"

	-- One APN is handled over the RNDIS interface, the other one over PPP
	device.host_interfaces = {
		eth = {
			{ proto = "dhcp", interface = device.network_interfaces[1] }
		},
		ppp = {
			{ proto = "ppp" }
		}
	}

	local control_ports = attty.find_tty_interfaces(device.desc, { number = 0x02 })
	if control_ports then
		table.insert(device.interfaces, { port = control_ports[1], type = "control" })
	end
	local modem_ports = attty.find_tty_interfaces(device.desc, { number = 0x3 })
	if modem_ports then
		table.insert(device.interfaces, { port = modem_ports[1], type = "modem" })
	end

	-- Temporary workaround for EG06 crashing
	if device.pid == "0306" then
		table.insert(device.command_blacklist, 'AT%+QCFG="band"')
		table.insert(device.command_blacklist, 'AT%+QNWLOCK')
	end

	device.ubus = ubus.connect()
	local events = {}
	events['network.link'] = function(...) link_changed(device, ...) end
	device.ubus:listen(events)

	setmetatable(mapper, Mapper)
	return mapper
end

return M