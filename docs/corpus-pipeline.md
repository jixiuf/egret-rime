# 语料管线（阶段 A~E）

> 目标：用自有语料（epub 电子书 + 听书/课程文稿）+ 开源语料，产出**词库（词典）**
> 与**语言模型（gram）**，并保持**增量可复跑**（epub 持续同步中，数据会不断增长）。
>
> 路径一律以仓库根为基准（`scripts/rime_paths.py`），不依赖 cwd。

## 0. 总览

```
data/input/                 ← 语料投放目录（任何来源、任何格式混放）
      │  extract.py: 按文件类型自动分派处理器
      ▼
data/corpus/extract/<格式>/...   一行一段的纯文本（阶段 A）
      │  clean.py: 白名单/去重/短句切分        （阶段 B）
      ▼
data/corpus/clean/{para,short}/...          整段语料 + LM 短句语料
      │  ├── freq.py: 分词 + 词频统计         （阶段 B）
      │  └── rime-gram: 字符 2-6gram 计数     （阶段 D）
      ▼
data/corpus/freq/*.tsv                      词频表 → 词库构建（阶段 C）
data/corpus/ngram/*.counts                  n-gram 计数 → kenlm → arpa → .gram（阶段 D）
      │
      ▼
dicts/**.dict.yaml  +  data/gram/*.gram     产物 → 评测（阶段 E）
```

## 1. 目录约定

| 路径 | 内容 | 入 git |
|---|---|---|
| `data/input/` | 语料投放目录（软链或实体皆可） | 否 |
| `data/corpus/extract/<格式>/<key前2位>/<key>.txt` | 抽取产物 | 否 |
| `data/corpus/meta/extract_index.jsonl` | 增量索引（append-only） | 否 |
| `data/corpus/log/` | 运行日志 | 否 |
| `data/corpus/{clean,freq,ngram}/` | 阶段 B/C/D 中间产物 | 否 |
| `scripts/corpus/` | 管线脚本 | **是** |
| `dicts/` | 词库源与产物 | **是** |

## 2. 阶段 A：抽取（单一入口，按类型自动分派）

```bash
make corpus-extract     # = scripts/corpus/extract.py --jobs 3 --nice 15
make corpus-dry-run     # 只看待处理清单 + 未识别格式列表
make corpus-status      # 语料账本
```

设计要点：

1. **不按来源写脚本**。`extract.py` 扫描 `data/input/`，对每个文件读头部
   512 字节 + 扩展名判定格式，交给 `formats.py` 里注册的处理器：
   `epub`（按 OPF spine 顺序取正文）/ `markdown` / `html` / 纯文本。
   新增格式只需在 `formats.py` 注册一个 `Handler` 子类。
   来源只体现在输出目录层级与索引记录里，不影响处理逻辑。
2. **未识别格式不静默丢弃**：`--unknown-list` 列出来（脚本/日志/tsv 等基础设施
   文件本就该跳过）。
3. **增量 key 策略**（避免为算 hash 去读几十 GB）：
   - 优先取同步清单（环境变量 `CORPUS_SYNC_MANIFEST` 指定，可选）的 `oss_key`
     （内容是内容寻址的 md5）；
   - 清单里没有的文件（手工投放/其他来源）回退 `sha256(内容)`。
4. **索引 append-only**，每完成一条落一行 → 中断可续；索引命中且产物仍在
   才跳过，**产物丢失会自动重抽**（自愈）。
5. **限流**：`nice=15` + `ioprio best-effort/7`（`common.throttle()`，ctypes 直调
   `ioprio_set`），并发默认 3。同机有其它服务时不会引起负载告警。

### 当前账本（2026-09-27）

| 格式 | 篇数 | 字符(亿) | 汉字(亿) |
|---|---:|---:|---:|
| epub（自有电子书） | 4,287 | 13.494 | 10.705 |
| markdown（自有听书+课程文稿） | 56,157 | 2.106 | 1.798 |
| text | 14 | 0.002 | 0.001 |
| **合计** | **60,458** | **15.601** | **12.504** |

抽取产物 4.10 GB；全量耗时约 1.4 分钟（epub）/ 14 秒（markdown），
均 3 并发。epub 数量随同步持续增长，重跑即增量补齐。

## 3. 阶段 B：清洗（待实现）

- 汉字白名单（8105 + 常用扩展），繁→简（OpenCC），去 URL/邮箱/控制字符。
- 样板段剔除：版权页 / ISBN / 出版社授权声明 / "Cover" / 目录行。
- 段落级去重：多版本 epub、重复版权页（SimHash 或规范化前缀哈希）。
- 产出两份语料：
  - `clean/para/`：整段 → 供分词与词频统计；
  - `clean/short/`：切到 10–20 字短句（按句末标点切分 + 长度过滤）
    → 供 n-gram 训练（短句是 LM 训练的标准输入形态）。

## 4. 阶段 C：词库（词典）

- **权重回归真值**：`base.small` 现有带宽仅 451–5000（中位 525），词间几乎无
  区分度 → 用 `freq/` 语料词频做 log-norm 重归一（对应
  `design-weights-jianma-grammar.md` §2.3 目标形态）。
- **语料新词表**：语料高频但现有词库没有的词（领域词/书名/现代用法）。
- **混合拼写词条**：高频二字词「首字五笔 2 码 + 次字拼音」（修 `ckwan→台湾`
  类词级 gram 盲区）。
- **成语 top-N**：语料频次 ≥3/百万者显式入传统库。
- 工具：`scripts/gen_wubi_py_unified_dicts.py`（生成）、
  `scripts/reweight_from_corpus.py`（用语料词频重写权重；默认 `REWEIGHT=off`）、
  `third-party/rime-corpus-processing/frequency`（Aho–Corasick 全量重扫词频）。

## 5. 阶段 D：gram（自训 LM）

```
clean/short/  →  rime-char-gram-builder（字符 2-6gram 计数，支持分片续跑）
              →  kenlm lmplz（modified KN，-S 限内存 + prune 控体积）
              →  arpa  →  build_grammar（librime-octagram 工具）
              →  data/gram/zh-hans-egret.gram
```

- 工具位置：`third-party/rime-corpus-processing/rime-gram/target/release/`、
  `third-party/kenlm/build/bin/lmplz`、`third-party/librime/build/bin/build_grammar`。
- **增量**：n-gram 计数是**可加量**。日常把新语料追加为新的计数分片，
  只在「合并 + 重训」时全量重跑（arpa→gram 约 1–2 小时，按新增 ≥5% 或每周触发）。
- 配比 = LM 口味：自有（epub+文稿）: 维基 : 新闻 需做 AB 实验。
- 对照基线：`zh-hans-t-essay-bgc`（现役，字级 27.7MB）、
  `wanxiang-lts-zh-hans`（词级，200MB）。

## 6. 阶段 E：评测

- `make test`（黄金用例，20 条，含 LM 级已知差异单独报告）。
- 21 例混流批（首字五笔 2 码 + 次字拼音）——对应 `lm-grammar.md` §5 的实测口径。
- `third-party/rime-build-grammar` 配套的 rime-schema-compare（大规模句子/文字
  正确率），用于词库/gram 改动的量化回归。
- **注意陷阱 #9**：prism 非确定性——同输入不同目录的 `prism.bin` md5 不同，
  贴脸的 LM 裁决会被翻转。判 failure 前与 `data/rime-test`（干净环境）交叉验证。

## 7. 踩坑记录

- `mv A B` 前先确认 B 不存在：`extract/文稿` → `extract/markdown` 时目标已存在，
  结果嵌套成 `markdown/文稿/`（已修，脚本改为按格式目录直出，不会再发生）。
- 输出临时文件带 `os.getpid()`：同内容多路径并发时避免撞名
  （同一批语料里有内容相同的重复文件）。
- 索引里的产物路径会过时（如目录改名）：`extract.py` 检测到产物丢失会自动重抽，
  也可用 `--force` 全量重来。
