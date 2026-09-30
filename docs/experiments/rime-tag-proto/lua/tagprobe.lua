-- 实验模块: 证明 lua_segmentor 的自定义 tag 能路由到只认该 tag 的 translator
local M = {}

local function tags_list(seg)
  local t = {}
  for k in pairs(seg.tags) do t[#t + 1] = k end
  table.sort(t)
  return table.concat(t, ",")
end

-- segmentor: 按首字符挂自定义 tag
M.route_seg = {
  func = function(segmentation, env)
    local input = segmentation.input
    local seg = segmentation:back()
    if not seg then
      print("[route_seg] empty segmentation, return true")
      return true
    end
    local j, k = seg.start, seg._end
    local text = input:sub(j + 1, k) -- lua 1-based
    local c = text:sub(1, 1)
    local tag = nil
    if c == "p" then
      tag = "py"
    elseif c == "w" then
      tag = "wubi"
    end
    print(string.format("[route_seg] round [%d,%d) text='%s' existing_tags={%s} -> %s",
      j, k, text, tags_list(seg), tag or "(none)"))
    if tag then
      local ns = Segment(j, k)
      ns.tags = { [tag] = true } -- 注意: set 语义, 键=tag, 值=true (不是数组)
      local ok = segmentation:add_segment(ns)
      print(string.format("[route_seg]   add_segment(tag=%s) -> %s ; back_tags={%s}",
        tag, tostring(ok), tags_list(segmentation:back())))
    end
    -- true = 继续让后面的 segmentor 跑
    return true
  end
}

-- lua translator: 配置 tag/tags 无效, 必须自己检查 seg:has_tag()
M.self_tag_translator = {
  func = function(input, seg, env)
    print(string.format("[LUA_TR] Query input='%s' tags={%s} (config tag 被忽略, 全靠自检)",
      input, tags_list(seg)))
    if seg:has_tag("py") or seg:has_tag("wubi") then
      yield(Candidate("lua", seg.start, seg._end, "LUA_TAG_OK(" .. input .. ")",
        "tags=" .. tags_list(seg)))
    end
  end
}

-- filter: 打印整份候选表
M.dump_filter = {
  func = function(input, env)
    local n = 0
    for cand in input:iter() do
      n = n + 1
      print(string.format("  [FILTER cand %d] type=%s text='%s' comment='%s' [%d,%d)",
        n, cand.type, cand.text, cand.comment or "", cand.start, cand._end))
      yield(cand)
    end
    print(string.format("  [FILTER] total candidates = %d", n))
  end
}


-- 额外: 把一段按规则切成两段, 各挂不同 tag (混流分段的雏形)
M.split_seg = {
  func = function(segmentation, env)
    local input = segmentation.input
    local seg = segmentation:back()
    if not seg then return true end
    local j, k = seg.start, seg._end
    local text = input:sub(j + 1, k)
    if text:match("^wu") and #text >= 4 then
      print(string.format("[split_seg] split '%s' [%d,%d)", text, j, k))
      segmentation:pop_back()
      local a = Segment(j, j + 2); a.tags = { wubi = true }
      segmentation:add_segment(a)
      segmentation:forward()
      local b = Segment(j + 2, k); b.tags = { py = true }
      segmentation:add_segment(b)
      print(string.format("[split_seg] -> size=%s ; seg0_tags={%s} seg1_tags={%s}",
        tostring(segmentation.size),
        tags_list(segmentation:get_at(0)), tags_list(segmentation:get_at(1))))
    end
    return true
  end
}

return M
