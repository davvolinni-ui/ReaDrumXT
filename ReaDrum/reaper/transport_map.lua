-- @noindex
-- Immutable Phase 3B.2a absolute-QN <-> project-time map. QN is quarter notes.
local M={MAGIC=52445,VERSION=1,MAX_ANCHORS=8192,MAX_SIGNATURES=256};local MOD=2147483647
local function finite(x)return type(x)=="number"and x==x and x~=math.huge and x~=-math.huge end
local function integer(x)return finite(x)and x==math.floor(x)end
local function cp(a)local b={};for i,v in ipairs(a)do if type(v)=="table"then b[i]={};for k,x in pairs(v)do b[i][k]=x end else b[i]=v end end;return b end
local function fail(s)error("transport map: "..s,3)end
local function sum(w)local c=1;for i=5,#w do local v=w[i];local fixed=v>=0 and math.floor(v*1000000+.5)or math.ceil(v*1000000-.5);c=(c*48271+(fixed%MOD))%MOD end;return c end
local function markers(x,q0,q1)
 if type(x)~="table"or#x>M.MAX_SIGNATURES then fail("signature capacity")end;local p=nil;for _,m in ipairs(x)do if not finite(m.qn)or not integer(m.num)or m.num<1 or not integer(m.den)or m.den<1 or m.qn<q0 or m.qn>q1 or(p and m.qn<=p)then fail("invalid signature marker")end;p=m.qn end
end
local function subdivide(f,q0,t0,q1,t1,rate,cap,state)
 local qs={q0+(q1-q0)*.25,q0+(q1-q0)*.5,q0+(q1-q0)*.75};local split=false;for _,q in ipairs(qs)do local t=f(q);if not finite(t)then fail("non-finite sample")end;if math.abs(t-(t0+(q-q0)*(t1-t0)/(q1-q0)))*rate>.25 then split=true end end
 if not split then state.n=state.n+1;if state.n>cap then fail("anchor capacity exceeded")end;return{{q=q0,t=t0},{q=q1,t=t1}}end
 local q,t=qs[2],f(qs[2]);local a=subdivide(f,q0,t0,q,t,rate,cap,state);local b=subdivide(f,q,t,q1,t1,rate,cap,state);table.remove(a);for _,v in ipairs(b)do a[#a+1]=v end;return a
end
function M.build(f,o)
 o=o or{};if type(f)~="function"then fail("sample function required")end;local r,q0,q1=o.sample_rate,o.qn_start,o.qn_end;if not integer(o.revision or 0)or(o.revision or 0)<0 or(o.revision or 0)>16777215 then fail("invalid revision")end;if not integer(r)or r<1 then fail("invalid sample_rate")end;if not finite(q0)or not finite(q1)or q1<=q0 then fail("invalid QN bounds")end;local cap=o.max_anchors or M.MAX_ANCHORS;if not integer(cap)or cap<2 or cap>M.MAX_ANCHORS then fail("invalid capacity")end;markers(o.time_signatures or{},q0,q1);local t0,t1=f(q0),f(q1);if not finite(t0)or not finite(t1)or t1<=t0 then fail("invalid time bounds")end;local a=subdivide(f,q0,t0,q1,t1,r,cap,{n=0});return{revision=o.revision or 0,sample_rate=r,qn_start=q0,qn_end=q1,time_start=t0,time_end=t1,anchors=cp(a),time_signatures=cp(o.time_signatures or{})}
end
function M.encode(m)
 if type(m)~="table"or not integer(m.revision)or m.revision<0 or m.revision>16777215 or not integer(m.sample_rate)or m.sample_rate<1 or not finite(m.qn_start)or not finite(m.qn_end)or m.qn_end<=m.qn_start or type(m.anchors)~="table"or #m.anchors<2 or #m.anchors>M.MAX_ANCHORS then fail("invalid map")end;markers(m.time_signatures or{},m.qn_start,m.qn_end);local w={M.MAGIC,M.VERSION,0,0,m.revision,m.sample_rate,m.qn_start,m.qn_end,m.time_start,m.time_end,#m.anchors,#m.time_signatures};local q,t=nil,nil;for _,a in ipairs(m.anchors)do if not finite(a.q)or not finite(a.t)or(q and(a.q<=q or a.t<=t))then fail("non-monotonic anchors")end;q,t=a.q,a.t;w[#w+1]=q;w[#w+1]=t end;for _,x in ipairs(m.time_signatures)do w[#w+1]=x.qn;w[#w+1]=x.num;w[#w+1]=x.den end;w[3]=#w;w[4]=sum(w);return{words=cp(w),checksum=w[4]}
end
function M.decode(w)
 if type(w)~="table"or# w<12 or w[1]~=M.MAGIC or w[2]~=M.VERSION or not integer(w[3])or w[3]~=#w or not finite(w[4])or w[4]~=sum(w)then return nil,"transport map: invalid header"end;local n,ts=w[11],w[12];if not integer(n)or n<2 or n>M.MAX_ANCHORS or not integer(ts)or ts<0 or ts>M.MAX_SIGNATURES or# w~=12+n*2+ts*3 then return nil,"transport map: invalid length"end;local m={revision=w[5],sample_rate=w[6],qn_start=w[7],qn_end=w[8],time_start=w[9],time_end=w[10],anchors={},time_signatures={}};if not integer(m.sample_rate)or m.sample_rate<1 or not finite(m.qn_start)or not finite(m.qn_end)or not finite(m.time_start)or not finite(m.time_end)or m.qn_end<=m.qn_start or m.time_end<=m.time_start then return nil,"transport map: invalid bounds"end;local p=13;for i=1,n do local q,t=w[p],w[p+1];if not finite(q)or not finite(t)or(i>1 and(q<=m.anchors[i-1].q or t<=m.anchors[i-1].t))then return nil,"transport map: non-monotonic anchors"end;m.anchors[i]={q=q,t=t};p=p+2 end;for i=1,ts do m.time_signatures[i]={qn=w[p],num=w[p+1],den=w[p+2]};p=p+3 end;if not pcall(markers,m.time_signatures,m.qn_start,m.qn_end)then return nil,"transport map: invalid signature marker"end;return{revision=m.revision,sample_rate=m.sample_rate,qn_start=m.qn_start,qn_end=m.qn_end,time_start=m.time_start,time_end=m.time_end,anchors=cp(m.anchors),time_signatures=cp(m.time_signatures)}
end
local function interp(a,key,v,out,den)if not finite(v)or v<a[1][key]or v>a[#a][key]then return nil,"transport map: out of coverage"end;for i=1,#a-1 do local x,y=a[i],a[i+1];if v>=x[key]and v<=y[key]then return x[out]+(v-x[key])*(y[out]-x[out])/(y[den]-x[den])end end;return a[#a][out]end
function M.qn_to_time(m,q)return interp(m.anchors,"q",q,"t","q")end
function M.time_to_qn(m,t)return interp(m.anchors,"t",t,"q","t")end
function M.publish(host,name,base,image)
 if type(host.gmem_attach)~="function"or type(host.gmem_write)~="function"then fail("gmem host required")end;base=base or 300000;host.gmem_attach(name or"ReaDrumSnapshot");host.gmem_write(base,0);for i,v in ipairs(image.words)do host.gmem_write(base+8+i,v)end;host.gmem_write(base+2,#image.words);host.gmem_write(base+3,image.checksum);host.gmem_write(base+4,image.words[5]);host.gmem_write(base+1,M.VERSION);host.gmem_write(base,M.MAGIC);return true
end
return M
