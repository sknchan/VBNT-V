--pretranslated: do not change this file
 
-- Enable localization
gettext.textdomain('webui-core')

local lp = require("web.lp")
local post_helper = require("web.post_helper")
local content_helper = require("web.content_helper")
local message_helper = require("web.uimessage_helper")
local ui_helper = require("web.ui_helper")

local wan = {
    iface = "uci.network.interface.@wan.ifname",
}
content_helper.getExactContent(wan)
local iface = wan.iface

local content, helpmsg

if iface then
    iface = iface:untaint()

    local gVNIR = post_helper.getValidateNumberInRange
    local mapValid = {
        adsl_vp = gVNIR(0, 255),
        adsl_vc = gVNIR(0, 65535),
    }

    local mapParams = {
        adsl_vp = "uci.xtm.atmdevice.@" .. iface .. ".vpi",
        adsl_vc = "uci.xtm.atmdevice.@" .. iface .. ".vci",
    }
    content, helpmsg = post_helper.handleQuery(mapParams, mapValid)
end
  ngx.print('\
\
');  
    lp.include("broadband-xdsl.lp")
  ngx.print('\
\
<fieldset>\
  ');  
    ngx.print(ui_helper.createMessages(message_helper.popMessages()))
    ngx.print('\
  <legend>');  ngx.print( T"Internet VPC" ); ngx.print('</legend>\
  ');  
    local html = {}
    if content and content.adsl_vp and content.adsl_vc then
        html[#html + 1] = ui_helper.createInputText(T"VP", "adsl_vp", content["adsl_vp"], nil, helpmsg["adsl_vp"])
        html[#html + 1] = ui_helper.createInputText(T"VC", "adsl_vc", content["adsl_vc"], nil, helpmsg["adsl_vc"])
    else
        html[#html + 1]=  ui_helper.createAlertBlock(T"Configuration of VP/VC not available")
    end
    ngx.print(html)
    ngx.print('\
</fieldset>'); 