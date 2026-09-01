-- Phase 3B.3 pure admission analysis for a promoted v2 image.
-- This module performs no host calls and does not publish or promote images.
local snapshot=require("ReaDrum.reaper.snapshot_v2")
local M={}

M.LIMITS={
 future_ons=8192,
 block_qn=1,
 block_clock_evaluations=8192,
 block_note_ons=4096,
 off_slots=8192,
 reconstruction_clocks=65536,
}
M.SAT=9007199254740991 -- greatest exactly representable integer in a double
M.QN_SCALE=1000000 -- host-supplied spans round upward to micro-QN

local SAT=M.SAT
local function gcd(a,b)a=math.abs(a);b=math.abs(b);while b~=0 do local r=a%b;a=b;b=r end;return a end
local function sat_add(a,b)if a>=SAT-b then return SAT,true end;return a+b,false end
local function sat_mul(a,b)if a==0 or b==0 then return 0,false end;if a>SAT/b then return SAT,true end;return a*b,false end
local function frac(n,d)
 assert(type(n)=="number"and type(d)=="number"and d>0,"invalid fraction")
 if n==0 then return{n=0,d=1}end
 local g=gcd(n,d);return{n=n/g,d=d/g}
end
local function fadd(a,b)
 local g=gcd(a.d,b.d);local ad=b.d/g;local bd=a.d/g
 return frac(a.n*ad+b.n*bd,a.d*ad)
end
local function fneg(a)return{n=-a.n,d=a.d}end
local function fsub(a,b)return fadd(a,fneg(b))end
local function fmul_int(a,n)return frac(a.n*n,a.d)end
-- Tiny unsigned big integers are used only for exact product comparison. All
-- source factors remain exact doubles/integers; limbs keep products below 2^53.
local BIG_BASE=1000000
local function big_int(x)local a={};repeat local q=math.floor(x/BIG_BASE);a[#a+1]=x-q*BIG_BASE;x=q until x==0;return a end
local function big_trim(a)while #a>1 and a[#a]==0 do a[#a]=nil end;return a end
local function big_mul(a,b)
 local out={};for i=1,#a+#b do out[i]=0 end
 for i=1,#a do local carry=0;for j=1,#b do local k=i+j-1;local x=out[k]+a[i]*b[j]+carry;local q=math.floor(x/BIG_BASE);out[k]=x-q*BIG_BASE;carry=q end;local k=i+#b;while carry>0 do local x=out[k]+carry;local q=math.floor(x/BIG_BASE);out[k]=x-q*BIG_BASE;carry=q;k=k+1;out[k]=out[k]or 0 end end
 return big_trim(out)
end
local function big_product(... )local out={1};for i=1,select("#",...)do out=big_mul(out,big_int(select(i,...)))end;return out end
local function big_add(a,b)local out,carry={},0;for i=1,math.max(#a,#b)do local x=(a[i]or 0)+(b[i]or 0)+carry;if x>=BIG_BASE then x=x-BIG_BASE;carry=1 else carry=0 end;out[i]=x end;if carry>0 then out[#out+1]=carry end;return out end
local function big_cmp(a,b)a=big_trim(a);b=big_trim(b);if #a~=#b then return #a<#b and-1 or 1 end;for i=#a,1,-1 do if a[i]~=b[i]then return a[i]<b[i]and-1 or 1 end end;return 0 end
local function ratio_products(a,b)return big_product(a.n,b.d),big_product(a.d,b.n)end
local function ratio_floor_info(a,b)
 if a.n<=0 then return 0,true,false end
 local top,bot=ratio_products(a,b)
 if big_cmp(top,big_mul(bot,big_int(SAT)))>=0 then return SAT,false,true end
 local approx=(a.n/a.d)/(b.n/b.d);local q=math.max(0,math.min(SAT-1,math.floor(approx)))
 while q>0 and big_cmp(top,big_mul(bot,big_int(q)))<0 do q=q-1 end
 while big_cmp(top,big_mul(bot,big_int(q+1)))>=0 do q=q+1 end
 return q,big_cmp(top,big_mul(bot,big_int(q)))==0,false
end
local function ratio_ceil(a,b)local q,exact,ov=ratio_floor_info(a,b);if ov then return SAT,true end;if exact then return q,false end;return sat_add(q,1)end
local function remainder_cmp(a,q,b,c)
 -- Compare a-q*b with c without constructing either rational product.
 local left=big_product(a.n,b.d,c.d)
 local qb=big_product(q,b.n,a.d,c.d);local cc=big_product(c.n,a.d,b.d)
 return big_cmp(left,big_add(qb,cc))
end
local function unit(l)return frac(4*l.num,l.den)end
local function max_step_occurrences(window,u,count,swing)
 if window.n<=0 then return 0,false end
 if count%2==0 then return ratio_ceil(window,fmul_int(u,count))end
 local period=fmul_int(u,2*count);local cycles,exact,ov=ratio_floor_info(window,period)
 if ov then return SAT,true end
 local base,ov1=sat_mul(cycles,2);if ov1 then return SAT,true end
 if exact then return base,false end
 local displacement=frac(u.n*math.abs(swing),u.d*200000)
 local short_gap=fsub(fmul_int(u,count),displacement)
 local extra=remainder_cmp(window,cycles,period,short_gap)<=0 and 1 or 2
 return sat_add(base,extra)
end
local function add_metric(metrics,key,value,overflow)
 local x,ov=sat_add(metrics[key],value);metrics[key]=x
 if overflow or ov then metrics.saturated[key]=true end
end
local function window_from_number(value,extra)
 local x=value+(extra or 0)
 if x<=0 then return frac(0,1),false end
 if x>SAT/M.QN_SCALE then return frac(SAT,1),true end
 -- Round upward to one micro-QN so admission never understates host input.
 return frac(math.ceil(x*M.QN_SCALE),M.QN_SCALE),false
end
local INT32_MAX=2147483647
local function integer(v,lo,hi)return type(v)=="number"and v==math.floor(v)and v>=lo and v<=hi end
local function decode_active(image)
 local w=image.words or image;local meta,err=snapshot.decode(w);if not meta then return nil,err end
 if not integer(w[7],0,snapshot.MAX_VARIATIONS)then return nil,"event budget: invalid active variation"end
 local lanes={};local links={};local grooves={};local lane;local pos=17;local expected,seen=0,0;local have_pattern,have_variation=false,false;local last_step=false
 local function finish_lane()if lane and seen~=expected then return nil,"event budget: lane step count mismatch"end;return true end
 while pos<=#w do
  local tag,n=w[pos],w[pos+1];local f=pos+2
  if not integer(tag,0,255)or not integer(n,0,#w)then return nil,"event budget: non-integer TLV header"end
  if tag==snapshot.TAG.PATTERN then
   local ok,e=finish_lane();if not ok then return nil,e end;if n~=3 then return nil,"event budget: invalid PATTERN length"end
   lane=nil;have_pattern=true;have_variation=false;last_step=false
  elseif tag==snapshot.TAG.VARIATION then
   local ok,e=finish_lane();if not ok then return nil,e end;if not have_pattern then return nil,"event budget: VARIATION before PATTERN"end;if n~=6 then return nil,"event budget: invalid VARIATION length"end
   lane=nil;have_variation=true;last_step=false
  elseif tag==snapshot.TAG.LANE then
   local ok,e=finish_lane();if not ok then return nil,e end;if not have_variation then return nil,"event budget: LANE before VARIATION"end;if n~=9 and n~=10 then return nil,"event budget: invalid LANE length"end
   local variation,count,num,den,phase,swing,velsens=w[f+1],w[f+3],w[f+4],w[f+5],w[f+6],w[f+7],w[f+8]
   if not integer(variation,1,snapshot.MAX_VARIATIONS)or not integer(count,1,4096)or not integer(num,1,INT32_MAX)or not integer(den,1,INT32_MAX)or not integer(phase,0,count-1)or not integer(swing,-100000,100000)or not integer(velsens,0,20000)then return nil,"event budget: invalid LANE budget field"end
   local groove_enabled=n<10 or w[f+9]==1;if n>=10 and w[f+9]~=0 and w[f+9]~=1 then return nil,"event budget: invalid groove bypass"end
   lane={variation=w[f+1],pad=w[f+2],count=w[f+3],num=w[f+4],den=w[f+5],phase=w[f+6],swing=w[f+7],velocity_sensitivity=w[f+8],groove_enabled=groove_enabled,steps={}}
   lanes[#lanes+1]=lane;expected=count;seen=0;last_step=false
  elseif tag==snapshot.TAG.GROOVE then
   local ok,e=finish_lane();if not ok then return nil,e end;if not have_variation or lane then return nil,"event budget: GROOVE out of order"end
   if n<6 then return nil,"event budget: invalid GROOVE length"end
   local variation,num,den,count,amount=w[f],w[f+1],w[f+2],w[f+3],w[f+4]
   if n~=5+count or not integer(variation,1,snapshot.MAX_VARIATIONS)or not integer(num,1,INT32_MAX)or not integer(den,1,INT32_MAX)or not integer(count,1,snapshot.MAX_GROOVE_STEPS)or not integer(amount,-100000,100000)then return nil,"event budget: invalid GROOVE field"end
   local maximum=0;for index=1,count do local value=w[f+4+index];if not integer(value,-960,960)then return nil,"event budget: invalid GROOVE offset"end;maximum=math.max(maximum,math.abs(value))end
   grooves[variation]={maximum=maximum,amount=amount};last_step=false
  elseif tag==snapshot.TAG.STEP then
   if n~=15 and n~=16 then return nil,"event budget: invalid STEP length"end;if not lane then return nil,"event budget: STEP before LANE"end;if seen>=expected then return nil,"event budget: too many STEP records"end
   local enabled,repeats,rn,rd,offset,gate=w[f],w[f+5],w[f+6],w[f+7],w[f+9],w[f+10]
   if not integer(enabled,0,3)or not integer(repeats,1,64)or not integer(rn,1,INT32_MAX)or not integer(rd,1,INT32_MAX)or not integer(offset,-960,960)or not integer(gate,0,16000000)then return nil,"event budget: invalid STEP budget field"end
   lane.steps[#lane.steps+1]={enabled=w[f],repeats=w[f+5],repeat_num=w[f+6],repeat_den=w[f+7],offset=w[f+9],gate=w[f+10]}
   seen=seen+1;last_step=true
  elseif tag==snapshot.TAG.LOCK then
   if n~=4 then return nil,"event budget: invalid LOCK length"end;if not last_step then return nil,"event budget: LOCK before STEP"end
  elseif tag==snapshot.TAG.PAD then
    if n~=15 and n~=16 and n~=17 and n~=18 then return nil,"event budget: invalid PAD length"end;if lane or have_variation or have_pattern then return nil,"event budget: PAD out of order"end
   if not integer(w[f],1,128)or not integer(w[f+5],0,snapshot.MAX_LINKS)then return nil,"event budget: invalid PAD budget field"end;links[w[f]]=1+w[f+5];last_step=false
  elseif tag==snapshot.TAG.GROUP then
   if n~=24 then return nil,"event budget: invalid GROUP length"end;if lane or have_variation or have_pattern then return nil,"event budget: GROUP out of order"end
   if not integer(w[f],1,128)or not integer(w[f+1],0,3)or not integer(w[f+2],0,1000000)or not integer(w[f+7],2,snapshot.MAX_GROUP_MEMBERS)then return nil,"event budget: invalid GROUP budget field"end;last_step=false
  elseif tag==snapshot.TAG.END_ then
   local ok,e=finish_lane();if not ok then return nil,e end;if n~=0 then return nil,"event budget: invalid END length"end;break
  else return nil,"event budget: unsupported TLV tag"
  end
  pos=pos+2+n
 end
 local active={};for _,l in ipairs(lanes)do if l.variation==meta.active_variation then
  l.expansion=links[l.pad]or 1;local g=l.groove_enabled and grooves[l.variation]
  local amount=g and math.max(0,math.min(100000,g.amount+l.swing))or 0
  l.groove_margin=g and frac(g.maximum*amount,960*100000)or frac(0,1);l.groove_active=g~=nil;active[#active+1]=l
 end end
 return active,meta
end

local reason_order={
 "block_qn_span_exceeded",
 "future_on_capacity_exceeded",
 "block_clock_budget_exceeded",
 "block_note_on_budget_exceeded",
 "off_capacity_exceeded",
 "reconstruction_clock_budget_exceeded",
}
function M.analyze(image,opt)
 opt=opt or{}
 local block_qn=opt.block_qn_span
 local reconstruction_qn=opt.reconstruction_qn_span
 if type(block_qn)~="number"or block_qn~=block_qn or block_qn<=0 or block_qn==math.huge then return nil,"block_qn_span must be finite and positive"end
 if type(reconstruction_qn)~="number"or reconstruction_qn~=reconstruction_qn or reconstruction_qn<0 or reconstruction_qn==math.huge then return nil,"reconstruction_qn_span must be finite and nonnegative"end
 local lanes,meta=decode_active(image);if not lanes then return nil,meta end
 local metrics={
  active_lanes=#lanes,required_future_ons=0,required_block_clock_evaluations=0,
  required_block_note_ons=0,required_retained_offs=0,required_off_slots=0,
  required_reconstruction_clocks=0,saturated={},
 }
 local bwindow,bwindow_sat=window_from_number(block_qn)
 local rwindow,rwindow_sat=window_from_number(reconstruction_qn,1)
 for _,l in ipairs(lanes)do
 local u=unit(l)
  local expansion=l.expansion or 1
  local schedule_swing=l.groove_active and 0 or l.swing
  local margin=fmul_int(l.groove_margin or frac(0,1),2)
  local clocks,ov=max_step_occurrences(fadd(bwindow,margin),u,1,schedule_swing);add_metric(metrics,"required_block_clock_evaluations",clocks,ov or bwindow_sat)
  local recon,rov=max_step_occurrences(fadd(rwindow,margin),u,1,schedule_swing);add_metric(metrics,"required_reconstruction_clocks",recon,rov or rwindow_sat)
  for _,s in ipairs(l.steps)do if s.enabled==1 or s.enabled==3 then
    local spacing=frac(4*s.repeat_num,s.repeat_den);local offset=frac(s.offset,960);local gate=s.enabled==1 and frac(u.n*s.gate,u.d*1000000) or nil
   for r=0,s.repeats-1 do
    local delay=fadd(offset,fmul_int(spacing,r));local future_window=fadd(fadd(frac(1,1),delay),margin)
    local future,fov=max_step_occurrences(future_window,u,l.count,schedule_swing);local mov;future,mov=sat_mul(future,expansion);add_metric(metrics,"required_future_ons",future,fov or mov)
    local burst,bov=max_step_occurrences(fadd(bwindow,margin),u,l.count,schedule_swing);burst,mov=sat_mul(burst,expansion);add_metric(metrics,"required_block_note_ons",burst,bov or mov)
     if gate then local retained,gov=max_step_occurrences(fadd(gate,margin),u,l.count,schedule_swing);retained,mov=sat_mul(retained,expansion);add_metric(metrics,"required_retained_offs",retained,gov or mov) end
   end
  end end
 end
 local combined,cov=sat_add(metrics.required_block_note_ons,metrics.required_retained_offs)
 metrics.required_off_slots=combined;if cov then metrics.saturated.required_off_slots=true end
 local values={
  block_qn_span_exceeded={required=block_qn,allowed=M.LIMITS.block_qn},
  future_on_capacity_exceeded={required=metrics.required_future_ons,allowed=M.LIMITS.future_ons},
  block_clock_budget_exceeded={required=metrics.required_block_clock_evaluations,allowed=M.LIMITS.block_clock_evaluations},
  block_note_on_budget_exceeded={required=metrics.required_block_note_ons,allowed=M.LIMITS.block_note_ons},
  off_capacity_exceeded={required=metrics.required_off_slots,allowed=M.LIMITS.off_slots},
  reconstruction_clock_budget_exceeded={required=metrics.required_reconstruction_clocks,allowed=M.LIMITS.reconstruction_clocks},
 }
 local saturation_key={future_on_capacity_exceeded="required_future_ons",block_clock_budget_exceeded="required_block_clock_evaluations",block_note_on_budget_exceeded="required_block_note_ons",off_capacity_exceeded="required_off_slots",reconstruction_clock_budget_exceeded="required_reconstruction_clocks"}
 local reasons={};for _,code in ipairs(reason_order)do local x=values[code];if x.required>x.allowed then reasons[#reasons+1]={code=code,required=x.required,allowed=x.allowed,saturated=metrics.saturated[saturation_key[code]]or false}end end
 return{accepted=#reasons==0,revision=meta.revision,active_variation=meta.active_variation,block_qn_span=block_qn,reconstruction_qn_span=reconstruction_qn,limits=M.LIMITS,metrics=metrics,reasons=reasons}
end
M.admit=M.analyze
return M
