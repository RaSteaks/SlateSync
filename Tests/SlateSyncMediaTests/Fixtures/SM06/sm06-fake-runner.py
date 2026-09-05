"""Offline, protocol-only child with explicit deterministic fault modes.

The language field selects faults, matching the retained Node fixture. Events
contain ownership/count metadata only; fake secrets are checked as booleans.
"""
import base64
import json
import os
import signal
import struct
import sys
import time

FINAL = "__SLATESYNC_OCR_JSON__"
PROGRESS = "__SLATESYNC_OCR_PROGRESS__"
CACHE = os.environ["PADDLE_PDX_CACHE_HOME"]

def event(kind):
    with open(os.path.join(CACHE,"events.jsonl"),"a",encoding="utf8") as f:
        f.write(json.dumps({"event":kind,"pid":os.getpid(),"secret":any(k in os.environ for k in ["OPENAI_API_KEY","ANTHROPIC_API_KEY","PIP_INDEX_URL"])})+"\n")

def emit(prefix, value, fragmented=False):
    data=(prefix+json.dumps(value,ensure_ascii=False,separators=(",",":"))+"\n").encode("utf8")
    if fragmented:
        for byte in data: os.write(1,bytes([byte]))
    else: os.write(1,data)

def dimensions(url):
    data=base64.b64decode(url.split(",",1)[1]); i=2
    while i<len(data):
        if data[i]!=255: i+=1; continue
        tag=data[i+1]; length=int.from_bytes(data[i+2:i+4],"big")
        if tag in [192,193,194]:
            h,w=struct.unpack(">HH",data[i+5:i+9]);return w,h
        i+=2+length
    raise ValueError("JPEG dimensions missing")

def recognize(payload,request_id=None):
    mode=payload.get("language","");event("recognize")
    emit(PROGRESS,{"requestId":request_id,"stage":"started","completedViews":0,"totalViews":1})
    if mode in ["delay","ignore-term"]:
        if mode=="ignore-term": signal.signal(signal.SIGTERM,signal.SIG_IGN)
        time.sleep(30 if mode=="ignore-term" else 0.7)
    if mode=="malformed": os.write(1,(FINAL+"{broken\n").encode());return
    if mode=="oversize": os.write(1,(FINAL+"x"*(32*1024*1024+1)).encode());return
    if mode in ["eof","server-exit"] and "--server" in sys.argv: sys.exit(2)
    if mode=="no-result": sys.exit(0)
    if mode=="stderr": os.write(2,b"noise"*60000)
    pages=[]
    for page in payload.get("pages",[]):
        views=[]
        for index,url in enumerate(page["images"]):
            width,height=dimensions(url)
            views.append({"viewIndex":index,"viewType":"full" if index==0 else "core-detail","width":width,"height":height,"durationMs":1,"truncated":False,"blocks":[{"order":0,"text":"场 镜 次 C001 😀","confidence":0.9,"bbox":[0,0,width,height],"bboxNormalized":[0,0,1,1]}]})
        pages.append({"pageNumber":page["pageNumber"],"views":views})
    response={"requestId":"wrong" if mode=="wrong-id" else request_id,"ok":True,"modelVersion":payload.get("modelVersion","fixture"),"pages":pages,"durationMs":1}
    if mode=="duplicate":
        data=(FINAL+json.dumps(response)+"\n")*2;os.write(1,data.encode());return
    emit(FINAL,response,fragmented=mode=="fragment")

event("start")
if "--check" in sys.argv:
    emit(FINAL,{"ok":True,"paddleVersion":"fixture","paddleOcrVersion":"fixture"});sys.exit(0)
if "--server" not in sys.argv:
    recognize(json.load(sys.stdin));sys.exit(0)
for line in sys.stdin:
    request=json.loads(line);kind=request.get("type");request_id=request.get("requestId")
    if kind=="shutdown": emit(FINAL,{"requestId":request_id,"ok":True});break
    if kind=="warmup":
        event("warmup")
        mode=request.get("language","")
        if mode=="server-unsupported": sys.exit(2)
        if mode=="timeout-warmup": time.sleep(30)
        emit(FINAL,{"requestId":request_id,"ok":True,"type":"warmup"})
    else: recognize(request["payload"],request_id)
