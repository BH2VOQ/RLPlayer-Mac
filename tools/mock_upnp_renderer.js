// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 August Hu <BH2VOQ@163.com>
//
// 本文件是 RLPlayer 的一部分，以 GNU 通用公共许可证第 3 版（或更新版本）发布。
// 完整条款见仓库根目录的 LICENSE 文件。
//
// mock_upnp_renderer.js — 本地假 UPnP MediaRenderer（自动化测试用；不打开音频设备、不出声）
// 用法：node tools/mock_upnp_renderer.js [port]   （默认 49199；GET /__state 可查调用记录）
// 提供 description.xml + AVTransport/ConnectionManager/RenderingControl 控制面；
// 只记录 SOAP 调用，不获取音频流、不出声。
// 环境变量：MOCK_UPNP_NO_RC=1 时不声明 RenderingControl 服务；
//          MOCK_UPNP_UDN 可指定 UDN（默认 uuid:mock-0000-1111-2222-333344445555）；
//          MOCK_UPNP_SSDP=1 时尝试作为 SSDP responder 响应 M-SEARCH（本机 UDP 1900 无属主才绑定）。
const http = require('http');
const dgram = require('dgram');
const PORT = parseInt(process.argv[2] || '49199', 10);
const state = { transport: 'STOPPED', uri: '', positionSec: 0, duration: '00:00:10', volume: 50, calls: [] };

function xmlEscape(s) {
  return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

const description = () => {
  const includeRc = !process.env.MOCK_UPNP_NO_RC;
  let services =
    '<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>' +
    '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>' +
    '<controlURL>/ctl/avt</controlURL><eventSubURL>/evt/avt</eventSubURL><SCPDURL>/avt.xml</SCPDURL></service>' +
    '<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>' +
    '<serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>' +
    '<controlURL>/ctl/cm</controlURL><eventSubURL>/evt/cm</eventSubURL><SCPDURL>/cm.xml</SCPDURL></service>';
  if (includeRc) {
    services +=
      '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>' +
      '<serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>' +
      '<controlURL>/ctl/rc</controlURL><eventSubURL>/evt/rc</eventSubURL><SCPDURL>/rc.xml</SCPDURL></service>';
  }
  const friendlyName = xmlEscape(process.env.MOCK_UPNP_NAME || 'Mock-N1000-Renderer');
  const udn = xmlEscape(process.env.MOCK_UPNP_UDN || 'uuid:mock-0000-1111-2222-333344445555');
  return '<?xml version="1.0"?>' +
    '<root xmlns="urn:schemas-upnp-org:device-1-0">' +
    '<specVersion><major>1</major><minor>0</minor></specVersion>' +
    '<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>' +
    '<friendlyName>' + friendlyName + '</friendlyName><manufacturer>RLPlayer</manufacturer>' +
    '<modelName>RLPlayer Mock Renderer</modelName>' +
    '<UDN>' + udn + '</UDN>' +
    '<serviceList>' + services + '</serviceList></device></root>';
};

const envelope = (serviceType, action, inner) => '<?xml version="1.0"?>' +
  '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
  's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
  '<u:' + action + 'Response xmlns:u="' + serviceType + '">' + inner +
  '</u:' + action + 'Response></s:Body></s:Envelope>';

const fmt = (s) => {
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return [h, m, sec].map((v) => (v < 10 ? '0' : '') + v).join(':');
};

const srv = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    if (req.method === 'GET' && req.url.indexOf('/description.xml') === 0) {
      res.writeHead(200, { 'Content-Type': 'text/xml; charset="utf-8"' });
      return res.end(description());
    }
    if (req.method === 'GET' && (req.url === '/avt.xml' || req.url === '/cm.xml' || req.url === '/rc.xml')) {
      res.writeHead(200, { 'Content-Type': 'text/xml; charset="utf-8"' });
      return res.end('<?xml version="1.0"?><scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion></scpd>');
    }
    if (req.method === 'GET' && req.url === '/__state') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(state));
    }
    if (req.method !== 'POST') { res.writeHead(404); return res.end(); }

    const rawSoapAction = String(req.headers['soapaction'] || '');
    const mm = /#([A-Za-z]+)/.exec(rawSoapAction);
    const action = mm ? mm[1] : '';
    let volumeVal = null;
    let serviceType = 'urn:schemas-upnp-org:service:AVTransport:1';
    if (rawSoapAction.indexOf('RenderingControl') !== -1) {
      serviceType = 'urn:schemas-upnp-org:service:RenderingControl:1';
    } else if (rawSoapAction.indexOf('ConnectionManager') !== -1) {
      serviceType = 'urn:schemas-upnp-org:service:ConnectionManager:1';
    }

    if (action === 'SetAVTransportURI') {
      const u = /<CurrentURI>([^<]*)<\/CurrentURI>/.exec(body);
      state.uri = u ? u[1] : '';
      state.transport = 'STOPPED';
      state.positionSec = 0;
    } else if (action === 'Play') {
      state.transport = 'PLAYING';
    } else if (action === 'Pause') {
      state.transport = 'PAUSED_PLAYBACK';
    } else if (action === 'Stop') {
      state.transport = 'STOPPED';
    } else if (action === 'Seek') {
      const t = /<Target>([^<]*)<\/Target>/.exec(body);
      if (t) {
        const p = t[1].split(':');
        state.positionSec = (parseInt(p[0], 10) || 0) * 3600 + (parseInt(p[1], 10) || 0) * 60 + (parseInt(p[2], 10) || 0);
      }
    } else if (action === 'SetVolume') {
      const v = /<DesiredVolume>([^<]*)<\/DesiredVolume>/.exec(body);
      if (v) {
        volumeVal = parseInt(v[1], 10);
        state.volume = volumeVal;
      }
    }
    state.calls.push({
      action,
      soapAction: rawSoapAction,
      transport: state.transport,
      uri: state.uri,
      volume: volumeVal !== null ? volumeVal : state.volume,
      body: body.slice(0, 300)
    });

    let inner = '';
    if (action === 'GetTransportInfo') {
      inner = '<CurrentTransportState>' + state.transport + '</CurrentTransportState>' +
              '<CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>';
    } else if (action === 'GetPositionInfo') {
      inner = '<Track>1</Track><TrackDuration>' + state.duration + '</TrackDuration>' +
              '<TrackMetaData></TrackMetaData><TrackURI>' + state.uri + '</TrackURI>' +
              '<RelTime>' + fmt(state.positionSec) + '</RelTime><AbsTime>' + fmt(state.positionSec) + '</AbsTime>' +
              '<RelCount>0</RelCount><AbsCount>0</AbsCount>';
    } else if (action === 'GetMediaInfo') {
      inner = '<NrTracks>1</NrTracks><MediaDuration>' + state.duration + '</MediaDuration>' +
              '<CurrentURI>' + state.uri + '</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>' +
              '<NextURI></NextURI><NextURIMetaData></NextURIMetaData><PlayMedium>NETWORK</PlayMedium>' +
              '<RecordMedium>NOT_IMPLEMENTED</RecordMedium><WriteStatus>NOT_IMPLEMENTED</WriteStatus>';
    } else if (action === 'GetProtocolInfo') {
      inner = '<Source></Source><Sink>http-get:*:audio/wav:*</Sink>';
    } else if (action === 'GetVolume') {
      inner = '<CurrentVolume>' + state.volume + '</CurrentVolume>';
    } else if (action === 'SetVolume') {
      inner = '';
    }
    res.writeHead(200, { 'Content-Type': 'text/xml; charset="utf-8"' });
    res.end(envelope(serviceType, action, inner));
  });
});
srv.listen(PORT, '127.0.0.1', () => {
  console.log('mock renderer on http://127.0.0.1:' + PORT + '/');

  if (process.env.MOCK_UPNP_SSDP === '1') {
    try {
      const udp = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      udp.on('error', (err) => {
        console.log('[SSDP] socket error (ignored):', err.message);
      });
      udp.on('message', (msg, rinfo) => {
        const s = msg.toString();
        // 限定响应针对 MediaRenderer 或 ssdp:all 的 M-SEARCH 测试
        if (s.includes('M-SEARCH') && (s.includes('MediaRenderer') || s.includes('ssdp:all') || s.includes('rootdevice'))) {
          const udn = process.env.MOCK_UPNP_UDN || 'uuid:mock-0000-1111-2222-333344445555';
          const resp =
            'HTTP/1.1 200 OK\r\n' +
            'CACHE-CONTROL: max-age=1800\r\n' +
            'EXT:\r\n' +
            'LOCATION: http://127.0.0.1:' + PORT + '/description.xml\r\n' +
            'SERVER: POSIX/1.0 UPnP/1.0 RLPlayerMock/1.0\r\n' +
            'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n' +
            'USN: ' + udn + '::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
          udp.send(Buffer.from(resp), rinfo.port, rinfo.address, () => {});
        }
      });
      udp.bind(1900, '0.0.0.0', () => {
        try {
          udp.addMembership('239.255.255.250');
          console.log('[SSDP] responder bound to 0.0.0.0:1900 and joined 239.255.255.250');
        } catch (e) {
          console.log('[SSDP] addMembership failed (ignored):', e.message);
        }
      });
    } catch (e) {
      console.log('[SSDP] bind failed (ignored):', e.message);
    }
  }
});
