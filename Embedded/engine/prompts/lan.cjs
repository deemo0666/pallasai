// lan_services: Bonjour services on the user's local network. See prompts/index.cjs.
module.exports = {
  system: 'For devices and services on the user\'s local network (printers, NAS and SMB shares, smart-home bridges, AirPlay or Cast receivers, web admin pages, SSH servers, the user\'s computers), call lan_services: Linux here cannot send multicast, so avahi, dns-sd and similar tools do not work in bash. Browse a type first, then resolve or connect by the service name. connect returns linux_address (use it from bash, e.g. curl http://10.0.2.2:PORT/) and address (127.0.0.1, for the other tools). To publish a server you started in bash, have it listen on 0.0.0.0 and start it with setsid -f nohup … so it outlives the command, then advertise its port. Only the declared types work; call types to see them.',

  description: 'Find, reach and publish Bonjour (mDNS / DNS-SD) services on the iPhone\'s local network. Actions: types (declared service types, optional category); browse (type, optional timeout seconds, default 3, p2p_only for AWDL only); resolve (connect once and report the path: name from browse, or host and port); connect (open a loopback TCP forward to a service: name, or host and port; returns id, address 127.0.0.1:PORT, linux_address 10.0.2.2:PORT for bash); advertise (publish a TCP server running in Linux: type, name, port it listens on inside Linux, txt entries "key=value"); list (open forwards and advertisements); stop (id, or all true). Only TCP is forwarded; _udp types can only be browsed. Returns JSON {ok, data} or {ok:false, error:{code, message}} with code invalid_args, authorization_denied, not_declared, not_available or internal_error. Forwards and advertisements pause while the app is in the background and come back when it is opened.',

  desktop: 'Use lan_services when the user asks to find or reach their local network devices or publish a service they started on this Mac. Browse the declared type first, then resolve or connect by name. From the Mac shell, use the loopback address returned by connect. To publish a local TCP server the user wants to share, start it on localhost before calling advertise. Call stop to end sharing when it is no longer needed.',

  desktopDescription: 'Find, reach and share Bonjour services on the Mac’s local network. Actions: types (declared types, optional category); browse (type, optional timeout and p2p_only); resolve (connect once and report the path); connect (open a loopback TCP forward to the named service or host and port; returns id and address); advertise (share a server listening on localhost, with type, name, port, and optional TXT entries); list (open forwards and advertisements); stop (id, or all true). Only TCP services can be connected or published. Returns JSON {ok, data} or {ok:false, error:{code, message}}. The Mac closes these listeners when its local Harness stops.',

  desktopPort: 'With host: its port. For advertise: the port of the server listening on localhost on this Mac.',

  params: {
    action: 'types, browse, resolve, connect, advertise, list or stop',
    type: 'Service type such as _http._tcp',
    name: 'Service name from browse (resolve, connect), or the name to publish (advertise)',
    domain: 'DNS-SD domain; default local.',
    host: 'Address to reach instead of a service name (resolve, connect)',
    port: 'With host: its port. For advertise: the port the server listens on inside Linux',
    txt: 'advertise: TXT entries as "key=value"',
    timeout: 'Seconds to wait, at most 60 (browse default 3, resolve default 5)',
    p2p_only: 'Use only a direct peer-to-peer (AWDL) link',
    category: 'types: one category to list',
    id: 'stop: the id from connect, advertise or list',
    all: 'stop: true to stop every forward and advertisement',
  },
};
