-- Deterministic reference for the Phase 3B.2 audio-thread scheduler. It only
-- consumes an immutable v2 image and is intentionally free of REAPER.
local snapshot=require("ReaDrum.reaper.snapshot_v2")
local M={}
local MOD=2147483647
local function rnd(s)return(s*48271)%MOD end
local function word(w,i)return w[i]end
local function groove_shift(plan,l,q)
 local g=plan.grooves and plan.grooves[l.variation]
 if not g or l.groove_enabled==false then return 0 end
 local unit=4*g.num/g.den;local slot=math.floor(q/unit+.5)
 if math.abs(q-slot*unit)>1e-8 then return 0 end
 local amount=math.max(0,math.min(100000,g.amount+l.swing))
 return(g.offsets[slot%g.count+1]or 0)/960*amount/100000
end
local function clock_qn(plan,l,k)
 local unit=4*l.num/l.den
 local straight=k*unit
 local groove=plan.grooves and plan.grooves[l.variation]
 if groove and l.groove_enabled~=false then return straight+groove_shift(plan,l,straight)end
 return straight+(((k+l.phase)%2==1)and(unit*l.swing/200000)or 0)
end
local function keyed_probability(plan,li,k,ppm)
 if ppm>=1000000 then return true end
 local h=(math.max(1,plan.seed%(MOD-1))+(li-1)*8191+k*131071)%MOD
 h=rnd(h)
 return((h-1)%1000000)<ppm
end
function M.compile(image)
 local w=assert(image.words or image,"v2 image required");assert(snapshot.decode(w))
 local p={lanes={},pads={},grooves={},variation=word(w,7),seed=1};local pos=17;local lane,step_no=0,0
 while pos<=#w do
  local tag,n=word(w,pos),word(w,pos+1);local f=pos+2
  if tag==snapshot.TAG.PATTERN then p.seed=word(w,f+1)
  elseif tag==snapshot.TAG.PAD then p.pads[word(w,f)]={default_pan=n>=16 and word(w,f+15) or 0}
  elseif tag==snapshot.TAG.LANE then
   lane={id=word(w,f),variation=word(w,f+1),pad=word(w,f+2),count=word(w,f+3),num=word(w,f+4),den=word(w,f+5),phase=word(w,f+6),swing=word(w,f+7),velocity_sensitivity=word(w,f+8) or 10000,groove_enabled=n<10 or word(w,f+9)==1,steps={}}
   p.lanes[#p.lanes+1]=lane;step_no=0
  elseif tag==snapshot.TAG.GROOVE then
   local count=word(w,f+3);local g={num=word(w,f+1),den=word(w,f+2),count=count,amount=word(w,f+4),offsets={}}
   for index=1,count do g.offsets[index]=word(w,f+4+index)end;p.grooves[word(w,f)]=g
  elseif tag==snapshot.TAG.STEP then
   step_no=step_no+1;lane.steps[step_no]={enabled=word(w,f),velocity=word(w,f+1),pitch=word(w,f+2),pitch_cents=word(w,f+3),pan=word(w,f+4),repeats=word(w,f+5),repeat_num=word(w,f+6),repeat_den=word(w,f+7),prob=word(w,f+8),offset=word(w,f+9),gate=word(w,f+10),condition=word(w,f+11),a=word(w,f+12),b=word(w,f+13),slide=n>=16 and word(w,f+14)==1}
  elseif tag==snapshot.TAG.END_ then break end
  pos=pos+2+n
 end
 local by_id={};for li,l in ipairs(p.lanes)do by_id[l.variation]=by_id[l.variation]or{};by_id[l.variation][l.id]=li end
 for li,l in ipairs(p.lanes)do for _,s in ipairs(l.steps)do if s.condition==6 then
  s.previous_lane=s.b==0 and li or by_id[l.variation][s.b]
  assert(s.previous_lane and p.lanes[s.previous_lane].variation==l.variation,"previous lane_id must name a lane in the same variation")
 end end end
 return p
end
local function base_pass(plan,l,s,k)
 if s.enabled~=1 and s.enabled~=3 then return false end
 if s.condition==1 then return k==0 end
 if s.condition==2 then return k~=0 end
 if s.condition==3 then return(math.floor(k/l.count)%s.a)==s.b end
 if s.condition==4 then return plan.fill==true end
 if s.condition==5 then return plan.fill~=true end
 return true
end
-- Resolve every clock tick from the origin through each lane's requested high
-- index. Ticks at the same clock QN form a batch: all conditions read the
-- histories that existed strictly before that QN, then the whole batch commits.
local function outcomes(plan,high)
 local next_k,last,result={},{},{}
 for li=1,#plan.lanes do next_k[li]=0;last[li]=false;result[li]={}end
 while true do
  local q
  for li,l in ipairs(plan.lanes)do local k=next_k[li];if l.variation==plan.variation and k<=high[li]then local x=clock_qn(plan,l,k);if not q or x<q then q=x end end end
  if not q then break end
  local batch={}
  for li,l in ipairs(plan.lanes)do local k=next_k[li];if l.variation==plan.variation and k<=high[li]and clock_qn(plan,l,k)==q then
   local ix=(k+l.phase)%l.count+1;local s=l.steps[ix];local ok=base_pass(plan,l,s,k)
   if ok and s.condition==6 then local prior=last[s.previous_lane];ok=(s.a==1 and prior)or(s.a==0 and not prior)end
   if ok then ok=keyed_probability(plan,li,k,s.prob)end
   result[li][k]=ok;batch[#batch+1]={li=li,k=k,ok=ok}
  end end
  for _,x in ipairs(batch)do last[x.li]=x.ok;next_k[x.li]=x.k+1 end
 end
 return result
end
-- Trace events use QN values and stable occurrence tokens. A token is derived
-- from (clock index, lane ordinal, repeat ordinal), never call/partition order.
function M.trace(plan,first_qn,last_qn,opt)
 opt=opt or{};plan.fill=opt.fill==true;local out={};local low,high={},{}
 for li,l in ipairs(plan.lanes)do
  if l.variation==plan.variation then local unit=4*l.num/l.den;low[li]=0;high[li]=math.max(0,math.ceil((last_qn+1+.5*unit)/unit)+1)else low[li]=0;high[li]=-1 end
 end
 local hit=outcomes(plan,high)
 for li,l in ipairs(plan.lanes)do if l.variation==plan.variation then
  local unit=4*l.num/l.den
  for k=low[li],high[li]do
   local ix=(k+l.phase)%l.count+1;local s=l.steps[ix];local q=clock_qn(plan,l,k)+s.offset/960
   if hit[li][k]then for r=0,s.repeats-1 do local on=q+r*4*s.repeat_num/s.repeat_den;local token=((k*#plan.lanes+(li-1))*64+r)+1;local gate=unit*s.gate/1000000;local off=on+gate;local pan=s.pan~=1001 and s.pan or (plan.pads[l.pad] and plan.pads[l.pad].default_pan or 0)
   if on>=first_qn and on<last_qn then local sens=math.max(1,l.velocity_sensitivity/10000);local deficit=math.max(0,(127-s.velocity)/127);local shift=math.max(0,math.min(1,(sens-1)*deficit^1.5));out[#out+1]={kind="on",qn=on,lane=li,pad=l.pad,note=math.max(0,math.min(127,69+s.pitch)),pitch_cents=s.pitch_cents,velocity=s.velocity,pan=pan,transient_shift=shift,slide=s.slide,token=token,repeat_index=r}end
     if s.enabled==1 and off>=first_qn and off<last_qn then out[#out+1]={kind="off",qn=off,lane=li,pad=l.pad,note=math.max(0,math.min(127,69+s.pitch)),token=token,repeat_index=r}end
   end end
  end
 end end
 table.sort(out,function(a,b)if a.qn~=b.qn then return a.qn<b.qn end;if a.lane~=b.lane then return a.lane<b.lane end;if a.repeat_index~=b.repeat_index then return a.repeat_index<b.repeat_index end;if a.kind~=b.kind then return a.kind=="on"end;return a.token<b.token end)
 return out
end
function M.schedule(image,first_qn,last_qn,opt)local p=M.compile(image);return M.trace(p,first_qn,last_qn,opt)end
return M
