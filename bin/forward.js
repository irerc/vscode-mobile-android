const net = require('net');
const LPORT = Number(process.env.FWD_LPORT || 8801);
const THOST = process.env.FWD_THOST || '127.0.0.1';
const TPORT = Number(process.env.FWD_TPORT || 8800);

const server = net.createServer(function (client) {
  const upstream = net.connect(TPORT, THOST);
  client.on('error', function () { upstream.destroy(); });
  upstream.on('error', function () { client.destroy(); });
  client.pipe(upstream);
  upstream.pipe(client);
});

server.listen(LPORT, '0.0.0.0', function () {
  console.log('forwarding 0.0.0.0:' + LPORT + ' -> ' + THOST + ':' + TPORT);
});