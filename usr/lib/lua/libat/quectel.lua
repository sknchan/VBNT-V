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
			local pin_type, pin_unlock_retries, pin_unblock_retries = line:match('+QPINC:%s?"(.-)",%s?(%d+),%s?(%d+)')
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
	elseif session.name == "internal_ims_pdn" then
		return device:send_singleline_command("AT+QIMSACT=1", "+QIMSACT:")
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
	elseif session.name == "internal_ims_pdn" then
		return device:send_singleline_command("AT+QIMSACT=0", "+QIMSACT:")
	end
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
				ipv4_state, ipv6_state = line:match("^$QCRMCALL:%s?(%d),V4$QCRMCALL:%s?(%d),V6$")
				if ipv4_state then
					break
				end
				local state, ip_type = line:match('$QCRMCALL:%s?(%d),(V%d)')
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
				local tx_bytes, rx_bytes = ret:match("^+QGDCNT:%s?(%d+),(%d+)$")
				if tx_bytes then
					info.packet_counters = {
						tx_bytes = tonumber(tx_bytes),
						rx_bytes = tonumber(rx_bytes)
					}
				end
			end
		end
	elseif session.name == "internal_ims_pdn" then
		info.session_state = "disconnected"
		ret = device:send_singleline_command("AT+QIMSACT?", "+QIMSACT:")
		if ret then
			local state = ret:match("+QIMSACT:%s?%d,(%d)")
			if state == "1" then
				info.session_state = "connected"
			end
		end
	end
end

function Mapper:get_network_info(device, info)
	local ret = device:send_singleline_command('AT+QENG="servingcell"', "+QENG:")
	if ret then
		local act = ret:match('+QENG:%s?"servingcell",".-","(.-)"')
		local cell_id
		if act == 'LTE' then
			local tracking_area_code
			cell_id, tracking_area_code = ret:match('+QENG:%s?"servingcell",".-","LTE",".-",%d+,%d+,(%x+),%d+,%d+,%d+,%d+,%d+,(%x+),[%d-]+,[%d-]+,[%d-]+,[%d-]+')
			if tracking_area_code then
				info.tracking_area_code = tonumber(tracking_area_code, 16)
			end
		elseif act == "GSM" or act == "WCDMA" then
			local location_area_code
			location_area_code, cell_id = ret:match('+QENG:%s?"servingcell",".-",".-",%d+,%d+,(%x+),(%x+)')
			if location_area_code then
				info.location_area_code = tonumber(location_area_code, 16)
			end
		end
		if cell_id then
			info.cell_id = tonumber(cell_id, 16)
		end

		local service_state = ret:match('+QENG:%s?"servingcell","(.-)"')
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
			local max_tx_rate, max_rx_rate = line:match('^+QGETMAXRATE:%s?1,".-",(%d+),(%d+)$')
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
	local neighbour_cells = {}
	ret = device:send_multiline_command('AT+QENG="neighbourcell"', "+QENG:")
	if ret then
		for _, line in pairs(ret) do
			local act = line:match('%+QENG:%s?"neighbourcell.-","(.-)"')
			if act == 'LTE' then
				local band_type, earfcn, phy_cell_id, rsrq, rsrp, rssi = line:match('%+QENG:%s?"neighbourcell(.-)","LTE",(%d+),(%d+),([%d-]+),([%d-]+),([%d-]+),[%d-]+')
				if band_type then
					local cell = {
						dl_earfcn = tonumber(earfcn),
						phy_cell_id = tonumber(phy_cell_id),
						rssi = tonumber(rssi),
						rsrp = tonumber(rsrp),
						rsrq = tonumber(rsrq)
					}
					if band_type ~= "" then
						cell.band_type = band_type:gsub("^ *", "")
					end
					table.insert(neighbour_cells, cell)
				end
			end
		end
	end
	info.neighbour_cells = neighbour_cells
end

local function get_complete_revision(device)
	local revision = device:get_revision()
	if revision then
		local prefix, suffix = revision:match("^(.+[FL]AR%d+A%d+)(M4G.*)$")
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
	local ret = device:send_singleline_command("AT+QTEMP", "+QTEMP:")
	if ret then
		local temperature = ret:match('^+QTEMP:%s?([%d-]+),[%d-]+,[%d-]+$')
		if temperature then
			info.temperature = tonumber(temperature)
		end
	end
end

local bandwidth_map = {
	['0'] = 1.4,
	['1'] = 3,
	['2'] = 5,
	['3'] = 10,
	['4'] = 15,
	['5'] = 20,
	['6'] = 1.4,
	['15'] = 3,
	['25'] = 5,
	['50'] = 10,
	['75'] = 15,
	['100'] = 20
}

function Mapper:get_radio_signal_info(device, info)
	local ret = device:send_singleline_command('AT+QNWINFO', "+QNWINFO:")
	if ret then
		info.radio_bearer_type = ret:match('+QNWINFO:%s?"(.-)"')
	end
	ret = device:send_singleline_command('AT+QENG="servingcell"', "+QENG:")
	if ret then
		local act = ret:match('+QENG:%s?"servingcell",".-","(.-)"')
		if act == 'LTE' then
			local phy_cell_id, earfcn, band, ul_bw, dl_bw, rsrp, rsrq, rssi, sinr, tx_power = ret:match('+QENG:%s?"servingcell",".-","LTE",".-",%d+,%d+,%x+,(%d+),(%d+),(%d+),(%d+),(%d+),%x+,([%d-]+),([%d-]+),([%d-]+),([%d-]+),[%d-]+,([%d-]+)')
			if not phy_cell_id then
				phy_cell_id, earfcn, band, ul_bw, dl_bw, rsrp, rsrq, rssi, sinr = ret:match('+QENG:%s?"servingcell",".-","LTE",".-",%d+,%d+,%x+,(%d+),(%d+),(%d+),(%d+),(%d+),%x+,([%d-]+),([%d-]+),([%d-]+),([%d-]+)')
			end
			info.lte_band = tonumber(band)
			info.lte_ul_bandwidth = bandwidth_map[ul_bw]
			info.lte_dl_bandwidth = bandwidth_map[dl_bw]
			info.rsrp = tonumber(rsrp)
			info.rsrq = tonumber(rsrq)
			info.rssi = tonumber(rssi)
			sinr = tonumber(sinr)
			if sinr then
				info.sinr = sinr * 2 - 20
			end
			tx_power = tonumber(tx_power)
			if tx_power and tx_power ~= -32768 then
				info.tx_power = tx_power/10
			end
			info.dl_earfcn = tonumber(earfcn)
			info.phy_cell_id = tonumber(phy_cell_id)
			ret = device:send_multiline_command("AT+QCAINFO", "+QCAINFO:")
			if ret then
				local carriers = {}
				for _, line in pairs(ret) do
					earfcn, dl_bw, band, phy_cell_id, rsrp, rsrq, rssi, sinr = line:match('+QCAINFO: %s?"sss",(%d+),(%d+),"LTE BAND (%d+)",%d+,(%d+),([%d-]+),([%d-]+),([%d-]+),([%d-]+)')
					if earfcn then
						local carrier = {
							dl_earfcn = tonumber(earfcn),
							phy_cell_id = tonumber(phy_cell_id),
							lte_band = tonumber(band),
							lte_dl_bandwidth = bandwidth_map[dl_bw],
							rsrp = tonumber(rsrp),
							rsrq = tonumber(rsrq),
							rssi = tonumber(rssi),
							sinr = tonumber(sinr)
						}
						table.insert(carriers, carrier)
					end
				end
				info.additional_carriers = carriers
			end
		elseif act == 'GSM' then
			local arfcn = ret:match('+QENG:%s?"servingcell",".-","GSM",%d+,%d+,%x+,%x+,%d+,(%d+)')
			info.dl_arfcn = tonumber(arfcn)
		elseif act == 'WCDMA' then
			local uarfcn, rscp, ecio = ret:match('+QENG:%s?"servingcell",".-","WCDMA",%d+,%d+,%x+,%x+,(%d+),%d+,%d+,([%d-]+),([%d-]+)')
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
		local data = ret:match('+QNVR:%s?"(.-)"')
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
		if hardware_version and (hardware_version:match("EC25AUTL") or hardware_version:match("EG06%-AUTL")) then
			info.cs_voice_support = false
			info.radio_interfaces = {
				{ radio_interface = "lte", supported_bands = get_supported_lte_bands(device) }
			}
			if hardware_version:match("EG06%-AUTL") then
				info.max_carriers = 2
			end
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
	audio_volume_level = { default = -1, type = "number" },
	audio_side_tone_gain = { default = 0, type = "number" },
	audio_mode = { default = 0, type = "number" },
	data_audio_digital_tx_gain = { default = 4096, type = "number" },
	data_audio_codec_tx_gain = { default = 5000, type = "number" },
	data_audio_digital_rx_gain = { default = 36000, type = "number" },
	data_audio_volume_level = { default = -1, type = "number" },
	data_audio_side_tone_gain = { default = 0, type = "number" },
	data_audio_mode = { default = 3, type = "number" },
	audio_codecs = { default = "AMR_WB;AMR;PCMA;PCMU", type = "string" },
	sip_user_agent = { default = 'Quectel <model> <software_version>', type = "string" },
	mbn_selection = { default = "none", type = "string" },
	data_call_codec = { default = "PCMU", type = "string" },
	ringing_timer = { default = 90000, type = "number" },
	enable_256qam = { default = "0", type = "string" },
	enable_lapi = { default = "0", type = "string" },
	early_media_rtp_polling_timer = { default = 1000, type = "number" },
	ue_usage_setting = { default = "keep", type = "string" },
	voice_domain_preference = { default = "keep", type = "string" }
}

local function set_config(device, config, facility, value, set_if_read_fails)
	-- Some commands fail to read before they are explicitly set
	local ret = device:send_singleline_command(string.format('AT+%s="%s"', config, facility), string.format("+%s:", config))
	if (not ret and set_if_read_fails) or (ret and ret:match('^+.-:%s?".-",([^,]+)') ~= value:gsub('"', '')) then
		ret = device:send_command(string.format('AT+%s="%s",%s', config, facility, value))
		if ret then
			return true
		end
	end
end

function Mapper:configure_device(device, config)
	local log = device.runtime.log

	if device.cops_pending then
		log:info("Not ready to continue configuration")
		return nil, "Not ready"
	end

	for k, v in pairs(config_defaults) do
		if v.type == "number" then
			config.device[k] = tonumber(config.device[k])
		end
		if not config.device[k] then
			config.device[k] = v.default
		end
	end

	local reset_required = false

	-- Select the MBN file before setting any NV items (either directly or
	-- indirectly) as otherwise their value will be overwritten when the MBN file
	-- is selected.
	if config.device.mbn_selection ~= "none" then
		if config.device.mbn_selection == "auto" then
			if set_config(device, "QMBNCFG", "AutoSel", "1", true) then
				device.runtime.log:notice("Enabled MBN auto-selection")
				reset_required = true
			end
		else
			local mbn_name = config.device.mbn_selection:gsub('^manual:', '') -- Strip the (optional) prefix.
			if set_config(device, "QMBNCFG", "AutoSel", "0", true) then
				log:notice("Disabled MBN auto-selection")
				reset_required = true
			end
			if set_config(device, "QMBNCFG", "Select", string.format('"%s"', mbn_name), true) then
				log:notice("Selected MBN '%s'", mbn_name)
				reset_required = true
			end
		end
	end

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

	-- Store the audio settings in the device so they can be accessed when a call
	-- is set up or when a call is converted from a voice call to a data call.
	device.audio_settings = {
		voice = {
			audio_digital_tx_gain = config.device.audio_digital_tx_gain,
			audio_codec_tx_gain = config.device.audio_codec_tx_gain,
			audio_digital_rx_gain = config.device.audio_digital_rx_gain,
			audio_volume_level = config.device.audio_volume_level,
			audio_side_tone_gain = config.device.audio_side_tone_gain,
			audio_mode = config.device.audio_mode
		},
		data = {
			audio_digital_tx_gain = config.device.data_audio_digital_tx_gain,
			audio_codec_tx_gain = config.device.data_audio_codec_tx_gain,
			audio_digital_rx_gain = config.device.data_audio_digital_rx_gain,
			audio_volume_level = config.device.data_audio_volume_level,
			audio_side_tone_gain = config.device.data_audio_side_tone_gain,
			audio_mode = config.device.data_audio_mode
		}
	}

	local padded_codecs = config.device.audio_codecs .. string.rep("\0", 128 - string.len(config.device.audio_codecs))
	local encoded_codecs = string.gsub(padded_codecs, ".", function(character)
		return string.format("%02X", string.byte(character))
	end)
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/ims/qipcall_audio_codec_list"', "+QNVFR:") ~= "+QNVFR: " .. encoded_codecs then
		if device:send_command('AT+QNVFW="/nv/item_files/ims/qipcall_audio_codec_list",' .. encoded_codecs) then
			log:info("Configured audio codecs")
			reset_required = true
		end
	end

	-- The ringing timer must be written in little endian order.
	local ringing_timer = ""
	for byte in string.gmatch(string.format("%08X", config.device.ringing_timer), "..") do
		ringing_timer = byte .. ringing_timer
	end
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/ims/qipcall_ringing_timer"', "+QNVFR:") ~= "+QNVFR: " .. ringing_timer then
		if device:send_command('AT+QNVFW="/nv/item_files/ims/qipcall_ringing_timer",' .. ringing_timer) then
			log:info("Configured ringing timer")
			reset_required = true
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
				if ret then
					log:info("Configured PCM channel")
					reset_required = true
				end
			end
		end
	end

	-- Disable the generation of the waiting tone as MMPBX already does this.
	-- Caution: Invalid AT command response (+QCFG instead of +QAUDCFG)
	ret = device:send_singleline_command('AT+QAUDCFG="toneswitch"', '+QCFG:')
	if ret and ret ~= '+QCFG: "toneswitch",1' then
		device:send_command('AT+QAUDCFG="toneswitch",1')
		log:info("Disabled waiting tone")
		reset_required = true
	end

	-- Deprecated parameter but enable it in order to make sure VoLTE keeps working
	if set_config(device, 'QCFG', 'volte_disable', '0', true) then
		log:info("Enabled VoLTE")
		reset_required = true
	end

	if config.device.volte_enabled then
		if set_config(device, 'QCFG', 'ims', '1', true)  then
			log:info("Enabled IMS PDN")
			reset_required = true
		end
	else
		if set_config(device, 'QCFG', 'ims', '2', true)  then
			log:info("Disabled IMS PDN")
			reset_required = true
		end
	end

	if config.device.ims_pdn_autobringup == '0' then
		device:send_command('AT+QIMSACT=0')
	else
		device:send_command('AT+QIMSACT=1')
	end

	local rtp_polling_timer_value = config.device.early_media_rtp_polling_timer
	if set_config(device, 'QIMSCFG', 'rtpdi_timer', string.format('%s', rtp_polling_timer_value))  then
		 log:info("Changed the value of early_media_rtp_polling_timer to: %s",  string.format('%s', rtp_polling_timer_value))
	else
		log:info("early_media_rtp_polling_timer value not changed")
	end

	local sim_hotswap_enabled = false
	ret = device:send_singleline_command('AT+QSIMDET?', "+QSIMDET:")
	if ret and ret:match('^+QSIMDET:%s?(%d),%d$') == '1' then
		sim_hotswap_enabled = true
	end
	if config.sim_hotswap and not sim_hotswap_enabled then
		-- Enable SIM hotswap events on low level GPIO transition
		device:send_command("AT+QSIMDET=1,0")
		log:info("Enabled SIM hotswap")
		reset_required = true
	elseif not config.sim_hotswap and sim_hotswap_enabled then
		-- Platform doesn't support SIM hotswap so disable it
		device:send_command("AT+QSIMDET=0,0")
		log:info("Disabled SIM hotswap")
		reset_required = true
	end

	local expected = '00'
	if config.device.enable_thin_ui_cfg == '0' then
		expected = '01'
	end

	-- Make sure that CFUN is set to 0 when the module is powered on.
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/Thin_UI/enable_thin_ui_cfg"', "+QNVFR:") ~= "+QNVFR: " .. expected then
		if device:send_command('AT+QNVFW="/nv/item_files/Thin_UI/enable_thin_ui_cfg",' .. expected) then
			log:info("Configured auto-attach")
			reset_required = true
		end
	end

	-- Disable sending automatic PDN disconnect requests for unused PDNs.
	if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/data/3gpp/ps/remove_unused_pdn"', "+QNVFR:") ~= "+QNVFR: 00" then
		if device:send_command('AT+QNVFW="/nv/item_files/modem/data/3gpp/ps/remove_unused_pdn",00') then
			log:info("Disabled sending automatic PDN disconnect requests for unused PDNs")
			reset_required = true
		end
	end

	-- Disable controlling the radio state using the GPIO.
	set_config(device, 'QCFG', 'airplanecontrol', '0', true)

	if config.device.enable_256qam == "1" then
		if set_config(device, 'QCFG', 'dl_256qam', '1', false)  then
			log:info("Enabled 256QAM support")
			reset_required = true
		end
	else
		if set_config(device, 'QCFG', 'dl_256qam', '0', false)  then
			log:info("Disabled 256QAM support")
			reset_required = true
		end
	end

	if config.device.enable_lapi == "1" then
		if set_config(device, 'QNWCFG', 'lapi', '1', false)  then
			log:info("Enabled LAPI support")
			reset_required = true
		end
	else
		if set_config(device, 'QNWCFG', 'lapi', '0', false)  then
			log:info("Disabled LAPI support")
			reset_required = true
		end
	end

	if config.device.ue_usage_setting == "delete" then
		if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/mmode/ue_usage_setting"', '+QNVFR:') and device:send_command('AT+QNVFD="/nv/item_files/modem/mmode/ue_usage_setting"') then
			log:info("Deleted UE usage setting")
			reset_required = true
		end
	elseif config.device.ue_usage_setting ~= "keep" then
		local ue_usage_setting
		if config.device.ue_usage_setting == "voice_centric" then
			ue_usage_setting = 0
		elseif config.device.ue_usage_setting == "data_centric" then
			ue_usage_setting = 1
		else
			return nil, "Invalid UE usage setting"
		end
		if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/mmode/ue_usage_setting"', '+QNVFR:') ~= string.format('+QNVFR: %02d', ue_usage_setting) then
			if device:send_command(string.format('AT+QNVFW="/nv/item_files/modem/mmode/ue_usage_setting",%02d', ue_usage_setting)) then
				log:info("Configured UE usage setting")
				reset_required = true
			end
		end
	end

	if config.device.voice_domain_preference == "delete" then
		if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/mmode/voice_domain_pref"', '+QNVFR:') and device:send_command('AT+QNVFD="/nv/item_files/modem/mmode/voice_domain_pref"') then
			log:info("Deleted voice domain preference")
			reset_required = true
		end
	elseif config.device.voice_domain_preference ~= "keep" then
		local voice_domain_preference
		if config.device.voice_domain_preference == "cs_voice_only" then
			voice_domain_preference = 0
		elseif config.device.voice_domain_preference == "ims_ps_voice_only" then
			voice_domain_preference = 1
		elseif config.device.voice_domain_preference == "cs_voice_preferred" then
			voice_domain_preference = 2
		elseif config.device.voice_domain_preference == "ims_ps_voice_preferred" then
			voice_domain_preference = 3
		else
			return nil, "Invalid voice domain preference"
		end
		if device:send_singleline_command('AT+QNVFR="/nv/item_files/modem/mmode/voice_domain_pref"', '+QNVFR:') ~= string.format('+QNVFR: %02d', voice_domain_preference) then
			if device:send_command(string.format('AT+QNVFW="/nv/item_files/modem/mmode/voice_domain_pref",%02d', voice_domain_preference)) then
				log:info("Configured voice domain preference")
				reset_required = true
			end
		end
	end

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

	if not lte_band_mask then
		lte_band_mask = helper.get_lte_band_mask(get_supported_lte_bands(device))
	end
	lte_band_mask = string.format("%x", lte_band_mask)

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

	if reset_required then
		log:warning("Resetting LTE module")
		-- Reset the device to apply the change
		device:send_command("AT+QPOWD=1")
		return nil, "Module reset required"
	end

	local roaming = 2
	if config.network.roaming == "none" then
		roaming = 1
	end
	ret = device:send_command(string.format('AT+QCFG="roamservice",%d,1', roaming))
	if not ret then
		return nil, "Failed to configure roaming"
	end

	-- Store the data call codec in device so it can be accessed when a voice call
	-- is converted to a data call.
	device.data_call_codec = config.device.data_call_codec

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

		if device.cops_command ~= cops_command then
			device.cops_command = cops_command
			device.cops_pending = true
			device:start_command(device.cops_command, 60000)
			return nil, "Not ready"
		end
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
		device:send_command('AT+CTZR=2')
		-- Enable packet domain events
		device:send_command('AT+CGEREP=2,1')
		-- Enable RmNet device status events
		device:send_command('AT+QNETDEVSTATUS=1')
		-- Enable voice call state change eventing
		device:send_command('AT^DSCI=1')
		-- Enable Distinctive Ring Information and RTP Stream Detection Information
		device:send_command('AT+QTELSTRASUP=1,1')
		-- Enable SIP status code reporting
		device:send_command('AT+QIMSCFG="QSIPRC_enable",1')
		-- Enable codec change reporting
		device:send_command('AT+QIMSCFG="QSPHCI_enable",1')
		-- Enable emergency support reporting
		device:send_command('AT+CNEM=1')

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

local function initiate_firmware_upgrade(device, path)
	local filename = "upgrade.zip"
	local buffer_size = 2 * 1024 * 1024
	local chunk_size = 64 * 1024

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
	local file_handle = open_result:match('%+QFOPEN:%s*(%d+)')
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

function Mapper:firmware_upgrade(device, path)
	if not path then
		device.buffer.firmware_upgrade_info.status = "invalid_parameters"
		return nil, "Invalid parameters"
	end

	-- If the module is currently trying to attach, postpone the firmware upgrade
	-- until the module is finished, otherwise start it immediately.
	if device.attach_pending or device.cops_pending then
		device.firmware_upgrade_path = path
	else
		return initiate_firmware_upgrade(device, path)
	end

	return true
end

function Mapper:get_firmware_upgrade_info(device)
	return device.buffer.firmware_upgrade_info
end

local function convert_time(datetime, tz, dst)
	local daylight_saving_time = tonumber(dst)
	local timezone = tonumber(tz) * 15
	local localtime
	local year, month, day, hour, min, sec = datetime:match("(%d+)/(%d+)/(%d+),(%d+):(%d+):(%d+)")
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
	-- locally held
	["1"] = {
		call_state = "connected",
		media_state = "local_held"
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
		call_state = "delivered",
		media_state = "normal"
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
	},
	-- remotely held
	["8"] = {
		call_state = "connected",
		media_state = "remote_held"
	},
	-- both locally and remotely held
	["9"] = {
		call_state = "connected",
		media_state = "local_and_remote_held"
	}
}

local dsci_call_type = {
	["0"] = "voice",
	["1"] = "data",
	["9"] = "emergency"
}

local release_reason_interval = 500

local function get_registration_state(device)
	local ret = device:send_singleline_command('AT+QCFG="ims"', '+QCFG:')
	if ret then
		if ret:match('^+QCFG:%s?"ims",%d,(%d)') == '1' then
			return 'registered'
		end
	end
	return 'not_registered'
end

local codec_ids = {
	["AMR"]    = 6,
	["AMR_WB"] = 7,
	["PCMU"]   = 11,
	["PCMA"]   = 13,
}

local function configure_audio(device, settings)
	-- Set the audio mode before setting the gains as setting the audio mode will overwrite the gains.
	if settings.audio_mode >= 0 then
		device:send_command(string.format('AT+QAUDMOD=%d', settings.audio_mode))
	end
	if settings.audio_codec_tx_gain >= 0 and settings.audio_digital_tx_gain >= 0 then
		device:send_command(string.format('AT+QMIC=%d,%d', settings.audio_codec_tx_gain, settings.audio_digital_tx_gain))
	end
	if settings.audio_digital_rx_gain >= 0 then
		device:send_command(string.format('AT+QRXGAIN=%d', settings.audio_digital_rx_gain))
	end
	if settings.audio_side_tone_gain >=0 then
		device:send_command(string.format('AT+QSIDET=%d', settings.audio_side_tone_gain))
	end
	if settings.audio_volume_level >= 0 then
		-- CLVL command is non-volatile so it should be issued if in any case and only if the volue value is different from the current one
		local ret_val = device:send_singleline_command('AT+CLVL?', "+CLVL:")
		if ret_val:match('+CLVL:%s?(%d)') ~= tostring(settings.audio_volume_level) then
			device:send_command(string.format('AT+CLVL=%d', settings.audio_volume_level))
		end
	end
end

local function switch_to_data_codec(device, call_id, codec_name)
	local desired_codec = codec_ids[codec_name]
	if not desired_codec then
		return nil, "Unsupported codec"
	end

	for _, result in pairs(device:send_multiline_command('AT+QIMSCFG="speech_codec"', '+QIMSCFG: "speech_codec"') or {}) do
		local current_codec, current_call_id = result:match('^%+QIMSCFG: "speech_codec",%d+,(%d+),%d+,(%d+)$')
		if current_codec and tonumber(current_call_id) == call_id then
			if tonumber(current_codec) == desired_codec then
				-- The codec is already the desired one, no need to change it.
				return true
			end

			break
		end
	end

	configure_audio(device, device.audio_settings.data)
	return device:send_command(string.format('AT+QIMSCFG="speech_codec",%d,%d', desired_codec, call_id))
end

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
	elseif prefix == "+CGEV" and message:match('NW DETACH') then
		device.runtime.log:warning("Received network detach indication")
		return true
	elseif prefix == "+QNWLOCK" or prefix == "+QUSIM" then
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
				device.buffer.firmware_upgrade_info.completion = 0
			elseif fota_command == "UPDATING" then
				local progress = tonumber(fota_arguments)
				if progress then
					device.buffer.firmware_upgrade_info.status = "flashing"
					device.buffer.firmware_upgrade_info.completion = progress
				end
			elseif fota_command == "END" then
				local error_code = tonumber(fota_arguments)
				if error_code ~= 0 then
					-- Do not send out done events as the postflash commands still have to run.
					send_firmware_upgrade_failed(device, firmware_upgrade.error_codes.download_failed)
				end
				device.buffer.firmware_upgrade_info.completion = nil
			end
			firmware_upgrade.update_state(device, device.buffer.firmware_upgrade_info)
			return true
		end
	elseif prefix == "^DSCI" then
		local call_id, direction, call_state, mode, remote_party, number_type = message:match('(%d+),(%d+),(%d+),(%d+),(.-),(%d+)')
		call_id = tonumber(call_id)
		local call_type = dsci_call_type[mode]
		if call_id and ( call_type == "voice" or call_type == "emergency" ) then
			local current_dsci_call_state = dsci_call_states[call_state].call_state
			device.calls[call_id] = device.calls[call_id] or {}
			device.calls[call_id].remote_party = remote_party
			device.calls[call_id].direction = voice.clcc_direction[direction]
			device.calls[call_id].number_format = voice.clcc_number_type[number_type]
			device.calls[call_id].call_type = call_type
			if call_type == "emergency" and not device.calls[call_id].emergency then
				device.calls[call_id].emergency = true
				device.runtime.log:debug("call with module_call_id=%d and mmpbx_call_id= %s is an emergency call" , call_id, tostring(device.calls[call_id].mmpbx_call_id))
			end
			device.runtime.log:debug("Processing DSCI: call_id=%d, call_state=%s, remote_party=%s, call_type=%s", call_id, tostring(current_dsci_call_state), tostring(remote_party), call_type)

			-- sip:mmtel is the remote party when we are getting connected to the conference server.
			-- if device.conference exists and sip:mmtel is the remote party it means that this is the first conference server related ^DSCI message
			-- we need to take the temporary stored mmpbx and media state taken form the call we decided to keep,
			-- in order to have consistent messaging towards mmpbx
			-- Note: For EC25 "sip:mmtel" applies. For EG06 "mmtel" applies
			-- Note: For EC25 in case of sip:mmtel only the "connected" state is seen in DSCI messaging
			if device.conference and (remote_party == "sip:mmtel" or remote_party == "mmtel") then
				device.calls[call_id].mmpbx_call_id = device.conference.mmpbx_call_id
				device.calls[call_id].media_state = device.conference.media_state
				device.conference = nil
			end

			if current_dsci_call_state == "disconnected" then
				if device.calls[call_id].call_state ~= "disconnected" then
					device.calls[call_id].call_state = current_dsci_call_state
					-- release process in case of conference call
					if device.calls[call_id].conference_processing then
						device.runtime.log:debug("release processing: module_call_id=%s, mmpbx_call_id= %s", tostring(call_id), tostring(device.calls[call_id].mmpbx_call_id))
						if device.calls[call_id].conference_processing == "release_mmpbx_callid" then
							send_call_disconnect_event(device, device.calls[call_id])
						end
						device.calls[call_id] = nil
						return true
					end

					if device.calls[call_id].release_reason then
						if device.calls[call_id].release_reason_timer then
							device.calls[call_id].release_reason_timer:cancel()
							device.calls[call_id].release_reason_timer = nil
						end
						send_call_disconnect_event(device, device.calls[call_id])
						device.calls[call_id] = nil
					else
						-- If the release reason is not set we are still expecting it. In this case the
						-- sending of the ubus event is delayed. A timer is started to send the event
						-- anyway if the event does not arrive within a certain interval.
						device.calls[call_id].disconnect_timer = device.runtime.uloop.timer(function()
							device.calls[call_id].release_reason = "normal"
							send_call_disconnect_event(device, device.calls[call_id])
							device.calls[call_id] = nil
						end, release_reason_interval)
					end
				else
					device.calls[call_id] = nil
				end
			elseif current_dsci_call_state == "dialing" or current_dsci_call_state == "alerting" then
				device.calls[call_id].call_state = current_dsci_call_state
				device.calls[call_id].media_state = dsci_call_states[call_state].media_state
				if not device.calls[call_id].mmpbx_call_id then -- occurs in case of call state alerting
					device.calls[call_id].mmpbx_call_id = device.mmpbx_call_id_counter
					device.mmpbx_call_id_counter = device.mmpbx_call_id_counter + 1
				end
				if remote_party ~= "sip:mmtel" and remote_party ~= "mmtel" then
					local event = {
						event = "call_state_changed",
						call_id = device.calls[call_id].mmpbx_call_id,
						dev_idx = device.dev_idx,
						call_state = device.calls[call_id].call_state,
						remote_party = remote_party,
						number_format = device.calls[call_id].number_format
					}
					if current_dsci_call_state == "alerting" and device.distinctive_ring then
						event.distinctive_ring = device.distinctive_ring
						device.distinctive_ring = nil
					end
					device:send_event("mobiled.voice", event)
				end
			else -- call state = connected or delivered -- media state handling included
				if device.calls[call_id].call_state ~= current_dsci_call_state then
					if remote_party ~= "sip:mmtel" and remote_party ~= "mmtel" then
						if current_dsci_call_state == "connected" and device.calls[call_id].call_state == "dialing" then
							device:send_event("mobiled.voice", {
								event = "call_state_changed",
								call_id = device.calls[call_id].mmpbx_call_id,
								dev_idx = device.dev_idx,
								call_state = "delivered",
								remote_party = remote_party,
								number_format = device.calls[call_id].number_format
							})
						end
						device:send_event("mobiled.voice", {
							event = "call_state_changed",
							call_id = device.calls[call_id].mmpbx_call_id,
							dev_idx = device.dev_idx,
							call_state = current_dsci_call_state,
							remote_party = remote_party,
							number_format = device.calls[call_id].number_format
						})
					end
					device.calls[call_id].call_state = current_dsci_call_state
					device.calls[call_id].media_state = dsci_call_states[call_state].media_state
				end
				-- media state changes handled
				local current_dsci_media_state = dsci_call_states[call_state].media_state
				if not device.calls[call_id].media_state then
					device.calls[call_id].media_state = current_dsci_media_state
				end
				if device.calls[call_id].media_state ~= current_dsci_media_state then
					device.calls[call_id].media_state = current_dsci_media_state
					--- send media_state_changed event
					device:send_event("mobiled.voice", {
						event = "media_state_changed",
						call_id = device.calls[call_id].mmpbx_call_id,
						dev_idx = device.dev_idx,
						media_state = device.calls[call_id].media_state
					})
					if device.calls[call_id].conference_processing == "reuse_mmpbx_callid" and device.conference then
						device.conference.media_state = current_dsci_media_state
					end
				end

				-- If MMPBX intructed the call to become a data call while the call was not
				-- established yet the call was marked to be convered to a data call. Now that
				-- the call is established the re-INVITE can be sent.
				if device.calls[call_id].data_call_codec then
					switch_to_data_codec(device, call_id, device.calls[call_id].data_call_codec)
					device.calls[call_id].data_call_codec = nil
				end
			end
		end
		return true
	elseif prefix == "+QSIPRC" then
		local call_id, status_code, method = message:match("^(%d+),(%d+)(.*)$")
		if call_id then
			call_id = tonumber(call_id)
			status_code = tonumber(status_code)
			if call_id ~= 255 then
				local call = device.calls[call_id]
				if call then
					if call.release_reason_timer then
						call.release_reason_timer:cancel()
						call.release_reason_timer = nil
					end

					if status_code == 200 or status_code == 0 then
						call.release_reason = "normal"
					elseif status_code == 486 or status_code == 600 then
						call.release_reason = "busy"
					elseif 400 <= status_code and status_code <= 699 then
						call.release_reason = "call_rejected"
					end

					if call.release_reason then
						if call.call_state == "disconnected" then
							if call.disconnect_timer then
								call.disconnect_timer:cancel()
								call.disconnect_timer = nil
							end
							send_call_disconnect_event(device, call)
							device.calls[call_id] = nil
						else
							-- If the call state is not (yet) disconnected, this URC is received before the
							-- DSCI URC or is not related to the call end. In order to avoid that in the
							-- latter case a disconnected event is sent with the wrong release reason
							-- because the URC with the actual release reason is received after the DSCI URC
							-- a timer is started that will erase the release reason again after a short
							-- amount of time.
							call.release_reason_timer = device.runtime.uloop.timer(function()
								call.release_reason = nil
								call.release_reason_timer = nil
							end, release_reason_interval)
						end
					end
				end
			elseif method == ',"REGISTER"' then
				device:send_event("mobiled.voice", {
					dev_idx = device.dev_idx,
					event = "registration_state_changed",
					registration_state = get_registration_state(device)
				})
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
		local msg_type, msg_count = message:match("^(%d+)%s*,%s*(%d+)")
		-- Check whether the match was successful and the message type is VOICE.
		if msg_type == "0" or msg_type == "255" then
			device.buffer.voice_info.messages_waiting = tonumber(msg_count)
			device:send_event("mobiled.voice", {
				dev_idx = device.dev_idx,
				event = "messages_waiting",
				messages_waiting = device.buffer.voice_info.messages_waiting
			})
		end
		return true
	elseif prefix == "+RTPDI" then
		-- Depending on the Quectel FW, the +RTPDI returns either only whether an RTP
		-- stream was detected or both whether an RTP stream was detected and the call
		-- ID for which the RTP stream was detected.
		local rtp_detected = message:match("^(%d+)") == "1"
		local call_id = tonumber(message:match("^%d+,(%d+)"))
		local mmpbx_call_id
		if call_id then
			local call = device.calls[call_id]
			if call and (call.call_state == "dialing" or call.call_state == "delivered") then
				mmpbx_call_id = call.mmpbx_call_id
			end
		else
			-- If the call ID is not specified look for a call that is in the dialing or
			-- delivered state and assume it is the one for which an RTP stream was detected.
			for _, call in pairs(device.calls) do
				if call.call_state == "dialing" or call.call_state == "delivered" then
					mmpbx_call_id = call.mmpbx_call_id
					break
				end
			end
		end
		if mmpbx_call_id then
			device:send_event("mobiled.voice", {
				dev_idx = device.dev_idx,
				call_id = mmpbx_call_id,
				event = "early_media",
				early_media = rtp_detected
			})
		end
		return true
	elseif prefix == "+DRI" then
		device.distinctive_ring = tonumber(message)
		return true
	elseif prefix == "+QSPHCI" then
		local codec, call_id = message:match("%d+,(%d+),%d+,(%d+)")

		-- Only send out the data_call event if the codec is changed to a G711 codec.
		if codec == "11" or codec == "13" then
			local call = device.calls[tonumber(call_id)]
			if call then
				device:send_event("mobiled.voice", {
					dev_idx = device.dev_idx,
					call_id = call.mmpbx_call_id,
					event = "data_call",
				})
				configure_audio(device, device.audio_settings.data)
			end
		end

		return true
	end
end

function Mapper:get_time_info(device, info)
	local ret = device:send_singleline_command("AT+QLTS=2", "+QLTS:")
	if ret then
		local datetime, tz, dst = ret:match('^+QLTS:%s?"([%d/,:]+)([%+%-%d]+),(%d)"')
		info.localtime, info.timezone, info.daylight_saving_time = convert_time(datetime, tz, dst)
		return true
	end
end

function Mapper:set_attach_params(device, profile)
	-- Prevent the module from attaching if it is currently uploading a firmware
	-- image as attaching might take a long time and would interfere with the upload.
	if device.firmware_upload or device.cops_pending then
		device.runtime.log:info("Not ready to set attach params")
		return nil, "Not ready"
	end

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
	if device.cops_command and not device.cops_pending then
		device.cops_pending = true
		device:start_command(device.cops_command, 60000)
	end

	return true
end

function Mapper:network_attach(device)
	-- Prevent the module from attaching if it is currently uploading a firmware
	-- image as attaching might take a long time and would interfere with the upload.
	if device.firmware_upload then
		device.runtime.log:info("Not ready to attach: firmware upgrade ongoing")
		return nil, "Firmware upgrade ongoing"
	end

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
		if message.command == device.cops_command then
			if not device:poll_command() then
				device.runtime.log:notice("Network selection failed")
			end
			device.cops_pending = nil
		elseif message.command == "AT+CGATT=1" then
			if not device:poll_command() then
				device.runtime.log:notice("Attach failed")
			end
			device.attach_pending = nil
		end

		if device.firmware_upgrade_path then
			initiate_firmware_upgrade(device, device.firmware_upgrade_path)
			device.firmware_upgrade_path = nil
		end
	elseif message.event == "command_cleared" then
		if message.command == "AT+CGATT=1" then
			device.attach_pending = nil
		elseif message.command == device.cops_command then
			device.cops_pending = nil
		end

		if device.firmware_upgrade_path then
			initiate_firmware_upgrade(device, device.firmware_upgrade_path)
			device.firmware_upgrade_path = nil
		end
	elseif message.event == "async_chunk_received" then
		if device.firmware_upload then
			local write_timeout = 5 -- s
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
		for _, call in pairs(device.calls) do
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

local function is_emergency_number(device, number)
	-- AT+CEN? returns lines that start with '+CEN1:' and lines that start with '+CEN2:'.
	-- Although we are only interested in lines starting with '+CEN2:', both have
	-- to be captured as otherwise they are treated as unsolicited messages.
	local ret = device:send_multiline_command('AT+CEN?', '+CE')
	if ret then
		for _, line in ipairs(ret) do
			if line:match('^%+CEN2:%s*%d+%s*,%s*(.+)$') == number then
				return true
			end
		end
	end

	ret = device:send_multiline_command('AT+QECCNUM?', '+QECCNUM:')
	if ret then
		for _, line in ipairs(ret) do
			if line:match('^%+QECCNUM:%s*[01]%s*,.*"' .. number .. '".*$') then
				return true
			end
		end
	end

	return false
end

function Mapper:dial(device, number)
	configure_audio(device, device.audio_settings.voice)

	local ret = device:send_command(string.format("ATD%s;", number))
	if ret then
		ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
		if ret then
			for _, call in pairs(ret) do
				local id, _, call_state, mode, _, _, _ = call:match('%+CLCC:%s*(%d+),(%d+),(%d+),(%d+),(%d+),"(.-)",(%d+)')
				id = tonumber(id)
				if voice.clcc_mode[mode] == "voice" then
					if voice.clcc_call_states[call_state].call_state == "dialing" or voice.clcc_call_states[call_state].call_state == "delivered" then
						if not device.calls[id] then
							device.calls[id] = {emergency = is_emergency_number(device, number)}
						end
						if not device.calls[id].mmpbx_call_id then
							device.calls[id].mmpbx_call_id = device.mmpbx_call_id_counter
							device.mmpbx_call_id_counter = device.mmpbx_call_id_counter + 1
						end

						local call_id_info = {call_id = device.calls[id].mmpbx_call_id}
						return call_id_info
					end
				end
			end
		end
	end
	return nil, "Dialing failed"
end

function Mapper:end_call(device, mmpbx_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	for call_id, call in pairs(device.calls) do
		if call.mmpbx_call_id == mmpbx_call_id then
			if call.emergency then
				-- AT+CHLD does not work for emergency calls as per 3GPP 24.610 supplementary
				-- services are not allowed for emergency calls.
				device:send_command('AT+CHUP', 5000)
			else
				device:send_command(string.format('AT+CHLD=1%d', call_id), 5000)
			end
			return true
		end
	end

	-- The module behaved incorrect with respect to conference handling. Corrective actions taken below as a workaround
	if device.conference and mmpbx_call_id == device.conference.mmpbx_call_id then
		local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")
		if ret then
			for _, call in pairs(ret) do
				local module_call_id, _, call_state, _, _, remote_party, _ = call:match('%+CLCC:%s*(%d+),(%d+),(%d+),(%d+),(%d+),"(.-)",(%d+)')
				if module_call_id then
					module_call_id = tonumber(module_call_id)
					if remote_party == "sip:mmtel" or remote_party == "mmtel" then
						device.calls[module_call_id] = device.calls[module_call_id] or {}
						device.calls[module_call_id].remote_party = remote_party
						device.calls[module_call_id].call_state = voice.clcc_call_states[call_state].call_state
						device.calls[module_call_id].media_state = voice.clcc_call_states[call_state].media_state
						device.calls[module_call_id].release_reason = "normal"
						device.calls[module_call_id].mmpbx_call_id = mmpbx_call_id
						device.conference = nil

						device:send_command(string.format('AT+CHLD=1%d', module_call_id), 5000)
						device.runtime.log:debug("End_call: conference call repair actions executed!!!!!")
						return true
					end
				end
			end
		end
	end
	return nil, "Unknown call ID"
end

local call_hold_resume_action_timer_interval = 2000

function Mapper:accept_call(device, mmpbx_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	if device.call_hold_or_resume_timer then
		device.runtime.log:debug("Accept call: IGNORE mmpbx_call_id= %s !!!!! Release timer", tostring(mmpbx_call_id))
		-- ignore call hold or call resume action
		device.call_hold_or_resume_timer:cancel()
		device.call_hold_or_resume_timer = nil
		return true
	end

	device.call_hold_or_resume_timer = device.runtime.uloop.timer(function()
		device.call_hold_or_resume_timer = nil
		device.runtime.log:debug("Accept call: device.call_hold_or_resume_timer is put to NIL !!!!!")
	end, call_hold_resume_action_timer_interval)
	device.runtime.log:debug("Accept call: device.call_hold_or_resume_timer is created !!!!!")

	for _, call in pairs(device.calls) do
		if call.mmpbx_call_id == mmpbx_call_id then
			if call.call_state ~= "alerting" then
				return nil, "Call in invalid state"
			end

			device.runtime.log:debug("Accept call: mmpbx_call_id= %s !!!!!", tostring(mmpbx_call_id))
			configure_audio(device, device.audio_settings.voice)
			return device:send_command("AT+CHLD=2", 5000)
		end
	end
	return nil, "Unknown call ID"
end

function Mapper:send_dtmf(device, tones, interval, duration)
	if not device:send_command(string.format('AT+VTD=%d,%d', duration or 3, interval or 0)) then
		return nil, "Failed to configure DTMF"
	end
	return device:send_command(string.format('AT+QVTS=%s', tones), 30 * 1000)
end

local function find_module_call_id(calls, mmpbx_call_id)
	for id, call in pairs(calls) do
		if call.mmpbx_call_id == mmpbx_call_id then
			return id, call
		end
	end
end

local function check_calls_status_and_correct(device)
	local ret = device:send_multiline_command("AT+CLCC", "+CLCC:")

	for module_call_id, call in pairs(device.calls) do
		module_call_id = tonumber(module_call_id)
		local keep_module_call_id = false
		for _, clcc_call in pairs(ret or {}) do
			local clcc_module_call_id = clcc_call:match('%+CLCC:%s*(%d+),%d+,%d+,%d+,%d+,".-",%d+')
			if clcc_module_call_id then
				if tonumber(clcc_module_call_id) == module_call_id then
					keep_module_call_id = true
					device.runtime.log:debug("confcall timeout cleaning actions: keep module call id = %d", module_call_id)
					break
				end
			end
		end
		if not keep_module_call_id then
			call.release_reason = "normal"
			call.call_state = "disconnected"
			send_call_disconnect_event(device, call)
			device.runtime.log:debug("confcall timeout cleaning actions: release module call id = %d, mmpbx_call_id= %d", module_call_id, call.mmpbx_call_id)
			device.calls[module_call_id] = nil
		end
	end
	device.runtime.log:debug("AT+CHLD=3 timeout repair actions executed!!!!!")
	return true
end

function Mapper:multi_call(device, mmpbx_call_id, action, mmpbx_second_call_id)
	mmpbx_call_id = tonumber(mmpbx_call_id)
	if not mmpbx_call_id then
		return nil, "Invalid call ID"
	end

	if action == "hold_call" or action == "resume_call" then
		device.runtime.log:debug("Multi call: action= %s, mmpbx_call_id= %s !!!!!", tostring(action), tostring(mmpbx_call_id))
		if device.call_hold_or_resume_timer then
			device.runtime.log:debug("Multi call: IGNORE action= %s, mmpbx_call_id= %s !!!!! Release timer", tostring(action), tostring(mmpbx_call_id))
			-- ignore call hold or call resume action
			device.call_hold_or_resume_timer:cancel()
			device.call_hold_or_resume_timer = nil
			return true
		end

		device.call_hold_or_resume_timer = device.runtime.uloop.timer(function()
			device.call_hold_or_resume_timer = nil
			device.runtime.log:debug("Multi call: device.call_hold_or_resume_timer is put to NIL !!!!!")
		end, call_hold_resume_action_timer_interval)
		device.runtime.log:debug("Multi call: device.call_hold_or_resume_timer is created !!!!!")


		for _, call in pairs(device.calls) do
			if call.mmpbx_call_id == mmpbx_call_id then
				if (action ~= "hold_call" or (call.media_state ~= "normal" and call.media_state ~= "remote_held"))
				   and (action ~= "resume_call" or (call.media_state ~= "local_held" and call.media_state ~= "local_and_remote_held")) then
					return nil, "Call in invalid state"
				end

				device:send_command("AT+CHLD=2", 5000)
				return true
			end
		end
		return nil, "Unknown call ID"
	elseif action == "conf_call" then
		mmpbx_second_call_id = tonumber(mmpbx_second_call_id)
		if not mmpbx_second_call_id then
			return "Invalid second call ID"
		end

		local module_call_id_1 = find_module_call_id(device.calls, mmpbx_call_id)
		local module_call_id_2 = find_module_call_id(device.calls, mmpbx_second_call_id)
		if not module_call_id_1 or not module_call_id_2 then
			return nil, "Conference setup error, one or two none existing callIDs"
		end

		-- choose which module_call_id/mmpbx_call_id to keep
		-- based on following algorithm
		-- if remote_party = mmtel it must be kept (regardless the media state of that call_id)
		-- else take the call_id with media_state == "normal"

		local module_call_id_to_keep
		local module_call_id_to_release
		local create_device_conference

		if device.calls[module_call_id_1].remote_party == "sip:mmtel" or device.calls[module_call_id_1].remote_party == "mmtel" then
			module_call_id_to_keep = module_call_id_1
			module_call_id_to_release = module_call_id_2
		elseif device.calls[module_call_id_2].remote_party == "sip:mmtel" or device.calls[module_call_id_2].remote_party == "mmtel" then
			module_call_id_to_keep = module_call_id_2
			module_call_id_to_release = module_call_id_1
		elseif device.calls[module_call_id_1].media_state == "normal" or device.calls[module_call_id_1].media_state == "remote_held" then
			module_call_id_to_keep = module_call_id_1
			module_call_id_to_release = module_call_id_2
			create_device_conference = true
		elseif device.calls[module_call_id_2].media_state == "normal" or device.calls[module_call_id_2].media_state == "remote_held" then
			module_call_id_to_keep = module_call_id_2
			module_call_id_to_release = module_call_id_1
			create_device_conference = true
		end
		if not module_call_id_to_keep then
			return nil, "Conference setup error, could not determine which mmpbx_call_id to keep"
		end

		device.runtime.log:debug("Multi call: module_call_id_to_keep= %s, module_call_id_to_release= %s, remote party to keep = %s", tostring(module_call_id_to_keep), tostring(module_call_id_to_release), tostring(device.calls[module_call_id_to_keep].remote_party))

		if device.calls[module_call_id_to_keep].media_state == "local_held" or device.calls[module_call_id_to_keep].media_state == "local_and_remote_held" then
			device.runtime.log:debug("Multi call: execute AT+CHLD=2 to change media state of module callid we want to keep = %s", tostring(module_call_id_to_keep))
			device:send_command("AT+CHLD=2", 5000)
		end

		local _, err, cme_err = device:send_command("AT+CHLD=3", 5000)
		device.runtime.log:debug("Multi call: AT+CHLD=3 returns: err = %s, cme_err = %s", tostring(err), tostring(cme_err))
		if err == "cme error" then
			device.runtime.log:debug("Multi call: media state of module_call_id_to_release = %s", tostring(device.calls[module_call_id_to_release].media_state))
			return nil, "Conference setup error, AT+CHLD=3 returned cme error"

		elseif  err == "timeout" then
			check_calls_status_and_correct(device)
			return nil, "Conference setup error, AT+CHLD=3 timed out"
		end

		if device.calls[module_call_id_to_keep].remote_party ~= "sip:mmtel" and device.calls[module_call_id_to_keep].remote_party ~= "mmtel" then
			device.calls[module_call_id_to_keep].release_reason = "normal"
			device.calls[module_call_id_to_keep].conference_processing = "reuse_mmpbx_callid"
		end
		device.calls[module_call_id_to_release].release_reason = "normal"
		device.calls[module_call_id_to_release].conference_processing = "release_mmpbx_callid"

		if create_device_conference then
			device.conference = {
				mmpbx_call_id = device.calls[module_call_id_to_keep].mmpbx_call_id,
				media_state = device.calls[module_call_id_to_keep].media_state
			}

			device.runtime.log:debug("Multi call: device.conference created. mmpbx_call_id = %s, media_state = %s", tostring(device.conference.mmpbx_call_id), tostring(device.conference.media_state))
		end

		return true
	end
	return nil, "Unsupported action"
end

function Mapper:convert_to_data_call(device, mmpbx_call_id, codec)
	local call_id, call = find_module_call_id(device.calls, mmpbx_call_id)
	if not call_id then
		return nil, "Unknown call ID"
	end

	-- Use the codec in UCI if none is specified by the caller.
	if not codec then
		codec = device.data_call_codec
	end

	-- A re-INVITE can only be sent after the connection has been established, i.e.,
	-- after the 200 OK for the invite has been received. In case the call has not
	-- been fully established yet, mark it as still to be converted to a data call
	-- and send the re-INVITE when the DSCI message is received.
	if not call.call_state or call.call_state == "dialing" or call.call_state == "alerting" or call.call_state == "delivered" then
		call.data_call_codec = codec
		return true
	end

	-- If the call is in the connected state the re-INVITE can be sent immediately.
	if call.call_state == "connected" then
		return switch_to_data_codec(device, call_id, codec)
	end

	-- In all other call states converting to a data call is not possible.
	return nil, "Invalid call state"
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
	info.volte.registration_status = get_registration_state(device)
	return true
end

function Mapper:set_emergency_numbers(device, numbers)
	-- This commit is a temoprary hack for the telstra delivery of MR1.5. The deleting of the existing emergency numbers is removed
	-- This is only done for the 18.1.c branch
	device.runtime.log:debug('set_emergency_numbers: setting emergeny numbers START')
	for _, number in pairs(numbers) do
		device.runtime.log:debug('set_emergency_numbers: print number= %s', tostring(number))
		if number ~= "911" and number ~= "112" then
			device:send_command(string.format('AT+QECCNUM=1,0,"%s"', number))
			device:send_command(string.format('AT+QECCNUM=1,1,"%s"', number))
		end
	end
	device.runtime.log:debug('set_emergency_numbers: setting emergeny numbers THE END')
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
			dial = "override",
			end_call = "override",
			accept_call = "override",
			send_dtmf = "override",
			multi_call = "override",
			convert_to_data_call = "override"
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

	if device.pid == "0125" then
		table.insert(device.command_blacklist, 'AT%+QCAINFO')
	end

	device.ubus = ubus.connect()
	local events = {}
	events['network.link'] = function(...) link_changed(device, ...) end
	device.ubus:listen(events)

	setmetatable(mapper, Mapper)
	return mapper
end

return M
