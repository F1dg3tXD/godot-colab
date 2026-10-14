@tool
## Reports how reachable a hosted session actually appears to be.
##
## We deliberately do not claim external reachability unless it was verified by
## a successful UPnP mapping or an explicit advertise host. Everything else is
## reported as LAN-only or unknown, never as "works over the internet".
class_name CollabConnectivity
extends RefCounted


## Enumerates non-loopback IPv4 addresses that a LAN peer could use.
static func lan_addresses() -> Array[String]:
	var out: Array[String] = []
	for address in IP.get_local_addresses():
		if not address.is_valid_ip_address():
			continue
		if address.begins_with("127.") or address == "::1":
			continue
		if address.contains(":"):
			continue # skip IPv6 for the simple LAN hint
		if address.begins_with("169.254."):
			continue
		out.append(address)
	return out


## Computes a connectivity descriptor.
## Returns { state: CollabConstants.ConnectivityState, detail: String,
## addresses: Array[String] }.
static func evaluate(advertise_host: String, upnp_external: String, upnp_attempted: bool) -> Dictionary:
	var addresses: Array[String] = lan_addresses()
	if not advertise_host.is_empty():
		return {
			"state": CollabConstants.ConnectivityState.DIRECT,
			"detail": "Advertising %s (manual/port-forwarded)." % advertise_host,
			"addresses": addresses,
		}
	if not upnp_external.is_empty():
		return {
			"state": CollabConstants.ConnectivityState.DIRECT,
			"detail": "UPnP mapped; external address %s." % upnp_external,
			"addresses": addresses,
		}
	if not addresses.is_empty():
		var detail: String = "LAN only (%s). Internet reachability unverified." % ", ".join(addresses)
		if upnp_attempted:
			detail += " UPnP failed or was unavailable."
		return {"state": CollabConstants.ConnectivityState.LAN_ONLY, "detail": detail, "addresses": addresses}
	return {
		"state": CollabConstants.ConnectivityState.UNKNOWN,
		"detail": "No reachable address detected. Check your network configuration.",
		"addresses": addresses,
	}
