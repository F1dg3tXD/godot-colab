@tool
## Optional UPnP UDP port forwarder.
##
## Discovery and mapping can fail on CGNAT, restrictive firewalls or routers
## without UPnP. Failures are reported rather than hidden and never block
## hosting. Any created mapping is removed on [method close].
class_name CollabUpnpForwarder
extends RefCounted

var _mapped_port: int = 0
var _mapped: bool = false
var _external_address: String = ""


## Attempts to map [param port] (UDP). Returns
## { ok: bool, external_address: String, error: String }.
func map(port: int) -> Dictionary:
	if _mapped and _mapped_port == port:
		return {"ok": true, "external_address": _external_address, "error": ""}
	var upnp := UPNP.new()
	var discover_code: int = upnp.discover(1000, 2, "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
	if discover_code != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "external_address": "", "error": "UPnP discovery failed (%d)" % discover_code}
	var gateway: UPNPDevice = upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		return {"ok": false, "external_address": "", "error": "no valid UPnP gateway"}
	var result: int = gateway.add_port_mapping(port, port, "godot_collab", "UDP", 0)
	if result != UPNP.UPNP_RESULT_SUCCESS:
		return {"ok": false, "external_address": "", "error": "UPnP mapping failed (%d)" % result}
	_mapped = true
	_mapped_port = port
	_external_address = gateway.query_external_address()
	return {"ok": true, "external_address": _external_address, "error": ""}


func external_address() -> String:
	return _external_address


func is_mapped() -> bool:
	return _mapped


## Removes any mapping this instance created.
func close() -> void:
	if not _mapped:
		return
	var upnp := UPNP.new()
	if upnp.discover(500, 2) == UPNP.UPNP_RESULT_SUCCESS:
		var gateway: UPNPDevice = upnp.get_gateway()
		if gateway != null and gateway.is_valid_gateway():
			gateway.delete_port_mapping(_mapped_port, "UDP")
	_mapped = false
	_external_address = ""
	_mapped_port = 0
