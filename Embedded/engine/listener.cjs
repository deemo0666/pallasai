// iOS may reclaim a suspended app's listening sockets. The engine keeps running, but its loopback
// listener stops accepting, and NodeMobile cannot be started a second time in the same process.
// This keeps hold of the loopback listeners so the app can have one listen again: on the same
// port when it is free, otherwise on a new one.
'use strict';
const net = require('node:net');

function trackLoopbackListeners(Server = net.Server) {
  /** port -> the server bound to it on 127.0.0.1 */
  const servers = new Map();
  const listen = Server.prototype.listen;
  Server.prototype.listen = function (...args) {
    this.once('listening', () => {
      const address = this.address();
      if (address && typeof address === 'object' && address.address === '127.0.0.1') servers.set(address.port, this);
    });
    return listen.apply(this, args);
  };

  /** Has the listener on `port` listen again; resolves to the port it is bound to now. */
  function relisten(port) {
    const server = servers.get(port);
    if (!server) return Promise.reject(Object.assign(new Error(`no loopback listener on ${port}`), { code: 'NO_LISTENER' }));
    return new Promise((resolve, reject) => {
      const attempt = (wanted, fallback) => {
        const onError = error => {
          server.off('listening', onListening);
          if (fallback && error.code === 'EADDRINUSE') attempt(0, false);
          else reject(error);
        };
        const onListening = () => {
          server.off('error', onError);
          const bound = server.address().port;
          servers.delete(port);
          servers.set(bound, server);
          resolve(bound);
        };
        server.once('error', onError);
        server.once('listening', onListening);
        listen.call(server, wanted, '127.0.0.1');
      };
      // Existing connections stay open; only the listening handle is replaced.
      if (server.listening) server.close();
      attempt(port, true);
    });
  }

  return { relisten };
}

module.exports = { trackLoopbackListeners };
