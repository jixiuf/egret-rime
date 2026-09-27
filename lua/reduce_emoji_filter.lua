-- lua/reduce_emoji_filter.lua
-- 降低 emoji 在候选页里的位置（原实现只认「4 字节的单个 emoji」，
-- 而 🇨🇳=8 字节、💪🏻️ 带变体选择符更长 → 大量漏检，候选页被 emoji 占位）。
--
-- 现在按码点范围判定，并把 emoji 候选整体挪到文本候选之后。
local M = {}

-- emoji / 符号码点区间（参照 Unicode Emoji 主干范围，覆盖常见情况）
local RANGES = {
  { 0x1F300, 0x1FAFF },  -- 杂项符号与象形、扩展-A
  { 0x1F000, 0x1F2FF },  -- 麻将/扑克/封闭字符
  { 0x1F1E6, 0x1F1FF },  -- 区域指示符（国旗）
  { 0x2600,  0x27BF  },  -- 杂项符号、装饰符号
  { 0x2190,  0x21FF  },  -- 箭头
  { 0x2B00,  0x2BFF  },  -- 杂项符号与箭头
  { 0xFE00,  0xFE0F  },  -- 变体选择符
  { 0x1F3FB, 0x1F3FF },  -- 肤色修饰符
  { 0x200D,  0x200D  },  -- ZWJ
  { 0x20E3,  0x20E3  },  -- 组合包围键帽
}

local function is_emoji_codepoint(cp)
  for _, r in ipairs(RANGES) do
    if cp >= r[1] and cp <= r[2] then return true end
  end
  return false
end

--- 全为 emoji/修饰符/空白即视为 emoji 候选
local function is_emoji_cand(cand)
  local text = cand.text
  if not text or text == "" then return false end
  local n = utf8.len(text)
  if not n then return false end
  local has_emoji = false
  for _, cp in utf8.codes(text) do
    if is_emoji_codepoint(cp) then
      has_emoji = true
    elseif cp == 0x20 or cp == 0x09 then
      -- 空白忽略
    else
      return false           -- 出现普通字符 → 不是纯 emoji 候选
    end
  end
  return has_emoji
end

function M.init(env)
  local config = env.engine.schema.config
  M.size = config:get_int("menu/page_size") or 5
end

function M.func(input, env)
  local text_cands, emoji_cands = {}, {}
  for cand in input:iter() do
    if is_emoji_cand(cand) then
      emoji_cands[#emoji_cands + 1] = cand
    else
      text_cands[#text_cands + 1] = cand
    end
  end
  for _, cand in ipairs(text_cands) do yield(cand) end
  for _, cand in ipairs(emoji_cands) do yield(cand) end
end

return M
