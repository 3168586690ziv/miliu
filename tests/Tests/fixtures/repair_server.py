import json, pathlib, struct, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
root=pathlib.Path(sys.argv[1]);source=pathlib.Path(sys.argv[2]);muxer=sys.argv[3];root.mkdir(parents=True,exist_ok=True)
(root/'source.mp4').write_bytes(source.read_bytes())
counts={}
for kind,selector in [('video','0:v:0'),('audio','0:a:0')]:
 track=root/(kind+'.mp4')
 subprocess.run([muxer,'-hide_banner','-loglevel','error','-nostdin','-y','-i',str(source),'-map',selector,'-c','copy','-movflags','frag_keyframe+empty_moov+default_base_moof','-frag_duration','2000000',str(track)],check=True)
 data=track.read_bytes();pos=0;init=b'';fragments=[];pending=b''
 while pos<len(data):
  size,tag=struct.unpack_from('>I4s',data,pos)
  if size==1:size=struct.unpack_from('>Q',data,pos+8)[0]
  if size==0:size=len(data)-pos
  atom=data[pos:pos+size];pos+=size
  if tag in [b'ftyp',b'moov']:init+=atom
  elif tag==b'moof':pending=atom
  elif tag==b'mdat' and pending:fragments.append(pending+atom);pending=b''
 (root/(kind+'-init.mp4')).write_bytes(init)
 for i,f in enumerate(fragments,1):(root/f'{kind}-{i}.m4s').write_bytes(f)
 counts[kind]=len(fragments)
 duration=10/len(fragments)
 lines=['#EXTM3U','#EXT-X-VERSION:7','#EXT-X-TARGETDURATION:10',f'#EXT-X-MAP:URI="{kind}-init.mp4"']
 for i in range(1,len(fragments)+1):lines += [f'#EXTINF:{duration:.6f},',f'{kind}-{i}.m4s']
 lines+=['#EXT-X-ENDLIST'];(root/(kind+'.m3u8')).write_text('\n'.join(lines)+'\n')
(root/'master.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English, stereo",DEFAULT=YES,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=320x176,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="aud"\nvideo.m3u8\n')
(root/'bad.m3u8').write_text('#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nmissing.ts\n#EXT-X-ENDLIST\n')
for mode in ['list','template']:
 blocks=[]
 for kind in ['video','audio']:
  if mode=='list':body=f'<SegmentList><Initialization sourceURL="{kind}-init.mp4"/>'+''.join(f'<SegmentURL media="{kind}-{i}.m4s"/>'for i in range(1,counts[kind]+1))+'</SegmentList>'
  else:body=f'<SegmentTemplate initialization="{kind}-init.mp4" media="{kind}-$Number$.m4s" startNumber="1" timescale="1000"><SegmentTimeline><S t="0" d="{round(10000/counts[kind])}" r="{counts[kind]-1}"/></SegmentTimeline></SegmentTemplate>'
  blocks.append(f'<AdaptationSet mimeType="{kind}/mp4"><Representation id="{kind}" bandwidth="1000000">{body}</Representation></AdaptationSet>')
 (root/(mode+'.mpd')).write_text('<MPD type="static" mediaPresentationDuration="PT10S"><Period>'+''.join(blocks)+'</Period></MPD>')
class Handler(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*args):pass
 def do_GET(self):
  path=urlsplit(self.path).path
  with (root/'requests.jsonl').open('a') as f:f.write(json.dumps({'path':path,'range':self.headers.get('Range'),'referer':self.headers.get('Referer')})+'\n')
  if path=='/dynamic':body=b'<html><body><script src="/player.js"></script></body></html>';mime='text/html'
  elif path=='/player.js':body=b'setTimeout(()=>{let v=document.createElement("video");v.src="/source.mp4?token=dynamic";v.preload="metadata";document.body.appendChild(v);},500);';mime='application/javascript'
  elif path=='/redirect-private':
   self.send_response(302);self.send_header('Location',f'http://127.0.0.2:{self.server.server_port}/private');self.send_header('Content-Length','0');self.end_headers();return
  else:
   file=root/path.lstrip('/')
   if file.parent!=root or not file.is_file():self.send_response(404);self.send_header('Content-Length','0');self.end_headers();return
   body=file.read_bytes();mime='application/vnd.apple.mpegurl' if file.suffix=='.m3u8' else ('application/dash+xml' if file.suffix=='.mpd' else 'video/mp4')
  code=200;range_header=self.headers.get('Range')
  if range_header and range_header.startswith('bytes='):
   lo,hi=range_header[6:].split('-');lo=int(lo);hi=min(int(hi) if hi else len(body)-1,len(body)-1);total=len(body);body=body[lo:hi+1];code=206
  self.send_response(code);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.send_header('Accept-Ranges','bytes')
  if code==206:self.send_header('Content-Range',f'bytes {lo}-{hi}/{total}')
  self.end_headers()
  try:self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler);print(server.server_port,flush=True);server.serve_forever()
