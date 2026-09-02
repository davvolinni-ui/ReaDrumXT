-- @noindex
-- Phase 3A protocol v1: fixed-width pad routing and one RR group only.
local M={MAGIC=52443,PROTOCOL_VERSION=1,SCHEMA_VERSION=1,MAX_MEMBERS=16}
M.runtime=require("ReaDrum.reaper.snapshot_v2")
M.transport=require("ReaDrum.reaper.transport_map")
M.event_budget=require("ReaDrum.reaper.event_budget")
M.MODE={sequential=0,ping_pong=1,random=2,random_no_repeat=3}
M.RESET={never=0,pattern=1,transport=2,trigger=3}
local function int(v,n,a,b) assert(type(v)=="number" and v==math.floor(v),n.." must be integer");assert(v>=a and v<=b,n.." out of range");return v end
function M.encode(rack,group,revision)
 assert(type(rack)=="table" and rack.type=="Rack","Rack is required");assert(type(group)=="table","RoundRobinGroup is required")
 local pads={};for _,p in ipairs(rack.pads or{})do pads[p.id]=p end
 assert(M.MODE[group.mode]~=nil,"unsupported mode");assert(M.RESET[group.reset_policy]~=nil,"unsupported reset policy")
 assert(#group.member_pad_ids>=1 and #group.member_pad_ids<=M.MAX_MEMBERS,"member count out of range")
 local s={magic=M.MAGIC,protocol_version=1,schema_version=1,revision=int(revision or 1,"revision",0,16777215),mode=M.MODE[group.mode],probability_ppm=math.floor(group.probability*10000+0.5),reset_policy=M.RESET[group.reset_policy],seed=int(group.seed,"seed",-2147483647,2147483647),advance_on_skip=group.advance_on_skip and 1 or 0,advance_each_repeat=group.advance_each_repeat and 1 or 0,member_count=#group.member_pad_ids,members={}}
 for i,id in ipairs(group.member_pad_ids)do local p=assert(pads[id],"unknown member pad");s.members[i]=int(p.logical_index,"logical_index",1,128)end
 return s
end
-- Write payload first and magic last, preventing JSFX from accepting a partial snapshot.
function M.write_fx(host,track,fx,s)
 host.TrackFX_SetParam(track,fx,0,0);local v={[1]=s.protocol_version,[2]=s.schema_version,[3]=s.revision,[4]=s.mode,[5]=s.probability_ppm,[6]=s.reset_policy,[7]=s.seed,[8]=s.advance_on_skip,[9]=s.advance_each_repeat,[10]=s.member_count}
 for i=1,M.MAX_MEMBERS do v[10+i]=s.members[i]or 0 end;for i=1,26 do host.TrackFX_SetParam(track,fx,i,v[i]or 0)end;host.TrackFX_SetParam(track,fx,0,s.magic);return true
end
-- v2 payload publication. Sliders 1..28 (indices 0..27) are never touched.
-- The shared-memory image and metadata are complete before commit slider 34.
function M.write_runtime_fx(host,track,fx,image,options)
 options=options or{};local base=options.base or 0;local token=options.token or image.revision
 M.runtime.publish(host,options.gmem_name or"ReaDrumSnapshot",base,image)
 host.TrackFX_SetParam(track,fx,28,M.runtime.MAGIC)
 host.TrackFX_SetParam(track,fx,29,M.runtime.VERSION)
 host.TrackFX_SetParam(track,fx,30,base)
 host.TrackFX_SetParam(track,fx,31,#image.words)
 host.TrackFX_SetParam(track,fx,32,image.checksum)
 host.TrackFX_SetParam(track,fx,33,token) -- commit last
 if options.promote_token~=nil then host.TrackFX_SetParam(track,fx,36,options.promote_token)end
 return true
end
-- Map payload is committed last and promoted explicitly, matching the v2 image.
function M.write_transport_map_fx(host,track,fx,image,options)
 options=options or{};local base=options.base or 300000;local token=options.token or image.words[5]
 M.transport.publish(host,options.gmem_name or"ReaDrumSnapshot",base,image)
 host.TrackFX_SetParam(track,fx,37,M.transport.MAGIC);host.TrackFX_SetParam(track,fx,38,M.transport.VERSION);host.TrackFX_SetParam(track,fx,39,base);host.TrackFX_SetParam(track,fx,40,#image.words);host.TrackFX_SetParam(track,fx,41,image.checksum);host.TrackFX_SetParam(track,fx,42,token)
 if options.promote_token~=nil then host.TrackFX_SetParam(track,fx,43,options.promote_token)end;return true
end
local function pair_error(analysis)
 local out={};for _,r in ipairs(analysis.reasons or{})do out[#out+1]=r.code.." ("..tostring(r.required).." > "..tostring(r.allowed)..")"end
 return "runtime/map admission rejected: "..table.concat(out,", ")
end
function M.admit_runtime_pair(image,map_image,options)
 options=options or{};local map,err=M.transport.decode(map_image.words or map_image);if not map then return nil,err end
 if map.revision~=image.revision then return nil,"runtime/map revision mismatch"end
 local max_block_samples=options.max_block_samples or 16384
 if type(max_block_samples)~="number"or max_block_samples~=math.floor(max_block_samples)or max_block_samples<1 then return nil,"max_block_samples must be a positive integer"end
 local block_qn=0;for i=1,#map.anchors-1 do local a,b=map.anchors[i],map.anchors[i+1];local span=(b.q-a.q)/(b.t-a.t)*max_block_samples/map.sample_rate;if span>block_qn then block_qn=span end end
 -- The dispatcher never walks from the beginning of the transport map to the
 -- current play position.  On a fresh start it backs up only a two-sample
 -- tolerance; on a loop/discontinuity it reconstructs at most one complete
 -- audio block.  Charging every lane for map.qn_end made a valid 128-lane kit
 -- fail admission solely because the map keeps a 256-QN scheduling horizon,
 -- leaving the previously published pattern active.
 local reconstruction_qn=block_qn
 local analysis,e=M.event_budget.analyze(image,{block_qn_span=block_qn,reconstruction_qn_span=reconstruction_qn});if not analysis then return nil,e end
 analysis.max_block_samples=max_block_samples
 if not analysis.accepted then return nil,pair_error(analysis),analysis end
 return analysis
end
function M.write_admitted_pair_fx(host,track,fx,image,map_image,options)
 options=options or{};local analysis,err,rejected=M.admit_runtime_pair(image,map_image,options);if not analysis then return nil,err,rejected end
 local token=options.token or image.revision;local promote=options.promote_token
 M.write_runtime_fx(host,track,fx,image,{gmem_name=options.gmem_name,base=options.runtime_base or 0,token=options.runtime_token or token,promote_token=options.runtime_promote_token or promote})
 M.write_transport_map_fx(host,track,fx,map_image,{gmem_name=options.gmem_name,base=options.map_base or 300000,token=options.map_token or token,promote_token=options.map_promote_token or promote})
 return true,analysis
end
return M
