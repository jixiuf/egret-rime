# egret-rime —— 白鹭五笔·拼音混流输入方案
#
# 路径约定：一切以本仓库根为基准（$(CURDIR)），不依赖 cwd。
#   third-party/   外部依赖源码与构建（不入 git，可 scripts/setup_env.sh 重建）
#   data/          语料/词频/测试环境/gram（不入 git）
#   dicts/         词库源与产物（入 git）
#
# 常用：
#   make setup          一键搭环境（克隆+编译+venv+gram）
#   make env-test       建仓库内测试用 Rime 用户目录 data/rime-test
#   make test           跑回归（黄金 33 条 + 契约）
#   make test-rebuild   清 build/用户词典后重新部署再跑
#   make gen            由 scripts/gen_wubi_py_unified_dicts.py 重生成词库
#
# 目标机部署（开发机只 push，目标机自己 pull）：
#   git pull --ff-only && make deploy && make reload
#     make deploy       软链 yaml/lua/opencc/dicts/gram 到输入法用户目录（TARGET=... 可覆盖）
#     make reload       重建 Rime build + 重启输入法（Linux=fcitx5 / macOS=Squirrel）
#   离线机器（无 git/无网）：make bundle 打运行时包 → 目标机 bash install.sh

REPO       := $(CURDIR)
THIRD      := $(REPO)/third-party
DATA       := $(REPO)/data
DICTS      := $(REPO)/dicts

# --- 部署目标（输入法用户目录）---------------------------------------------
UNAME := $(shell uname)
ifeq ($(UNAME), Linux)
    DEFAULT_TARGET := $(HOME)/.local/share/fcitx5/rime/
else
    DEFAULT_TARGET := $(HOME)/Library/Rime/
endif
TARGET ?= $(DEFAULT_TARGET)

# --- 关键路径 ---------------------------------------------------------------
LIBRIME_BIN := $(THIRD)/librime/build/bin
GRAM_DIR    := $(DATA)/gram
GRAM        := $(GRAM_DIR)/zh-hans-t-essay-bgc.gram
TEST_DIR    := $(REPO)/data/rime-test
SHARED_DIR  := $(REPO)/data/rime-shared
PY          := $(THIRD)/venv/bin/python
PYTHON      ?= $(if $(wildcard $(PY)),$(PY),python3)

GRAM_URL := https://github.com/lotem/rime-octagram-data/releases/download/20260712/zh-hans-t-essay-bgc.gram

# deploy 用：允许 TARGET 带/不带尾斜杠（此前写死 $(TARGET)dicts，传 /x 会拼成 /xdicts）
TARGET_DIR := $(patsubst %/,%,$(TARGET))
# 运行时真正用的语言模型（万象词级）；essay gram 是 Lua 重排时代的遗留，不再部署。
# 400MB，**不随仓库/部署包分发** ⇒ `make deploy` 发现缺失会自动下载（可断点续传）。
GRAM_LM := $(GRAM_DIR)/wanxiang-lts-zh-hans.gram
GRAM_LM_URL ?= https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram

.PHONY: bundle reload setup setup-clone setup-build setup-gram env-test deploy test test-rebuild gen clean-test check paths corpus-extract corpus-dry-run corpus-status tiers tier refresh refresh-list reweight eval-gram verify-wubi bench verify verify-bundle gram-lm gram-essay

# --- 环境搭建 ---------------------------------------------------------------
setup:            ## 一键：克隆第三方 + 编译 + venv + gram
	bash scripts/setup_env.sh all

setup-clone:
	bash scripts/setup_env.sh clone

setup-build:
	bash scripts/setup_env.sh build

setup-gram: gram-lm   ## 下载运行时语言模型（= make gram-lm，万象词级）

gram-essay: $(GRAM)   ## 仅评测 A/B 用（essay 字级 gram，方案运行时不用它）

$(GRAM):
	mkdir -p $(GRAM_DIR)
	@if command -v proxychains4 >/dev/null 2>&1; then \
		proxychains4 -q curl -sL -o $@ $(GRAM_URL); \
	else \
		curl -sL -o $@ $(GRAM_URL); \
	fi
	@ls -la $@

# --- 测试环境（仓库内自包含，等价于 macOS 的 ~/rime-test）-------------------
env-test:
	@# 分档词表是生成产物（不入 git，见 .gitignore）：缺失时自动跑一次 dict 阶段，
	@# 保证新克隆 `make test` 也能通过（唯一入口仍是 scripts/refresh.sh）
	@[ -f "$(REPO)/dicts/egret_wubi_words_wangxiang_base.dict.yaml" ] || \
	  { echo "生成产物缺失，自动跑 scripts/refresh.sh --only dict ..."; \
	    bash "$(REPO)/scripts/refresh.sh" --only dict >/dev/null 2>&1 || true; }
	@mkdir -p $(TEST_DIR)/build
	@# 一律用**相对**软链（scripts/rel_symlink.py）：整棵树可搬迁、链不会断
	@for f in $(REPO)/*.yaml; do \
		case "$$(basename $$f)" in \
			user.yaml|default.custom.yaml) ;; \
			*) $(PYTHON) $(REPO)/scripts/rel_symlink.py $(TEST_DIR)/$$(basename $$f) "$$f" --quiet ;; \
		esac \
	done
	@# 用户态配置用复制而非软链: console/deployer 会回写这两个文件,
	@# 软链会把改动写到仓库里(见 AGENTS.md 陷阱 #1)
	@cp -f $(REPO)/user.yaml $(REPO)/default.custom.yaml $(TEST_DIR)/
	@# 测试环境专用：用户配置是「追加」语义（不动用户已有方案列表），但 console 只看
	@# schema 列表顺序 ⇒ 把**测试目录的这份**改成替换式，保证测的是本方案（§4.78）
	@$(PYTHON) $(REPO)/scripts/schema_env.py list-replace $(TEST_DIR)
	@# 测试环境的 LM 必须与生产一致（`make eval` 会临时改成自训 gram 做 A/B，
	@# 残留会让黄金/探针跑在错误的 LM 上 —— 真实踩过一次，见 §4.82）
	@printf 'patch:\n  grammar/language: wanxiang-lts-zh-hans\n' > $(TEST_DIR)/egret_wubi_py.custom.yaml
	@for d in dicts lua opencc; do $(PYTHON) $(REPO)/scripts/rel_symlink.py $(TEST_DIR)/$$d $(REPO)/$$d --quiet; done
	@mkdir -p $(SHARED_DIR)
	@for f in default.yaml symbols.yaml essay.txt; do \
		$(PYTHON) $(REPO)/scripts/rel_symlink.py $(SHARED_DIR)/$$f $(LIBRIME_BIN)/$$f --quiet; \
	done
	@# 关键: console 运行时 user_data_dir 与 shared_data_dir 均为 "."（librime 默认），
	@# 所以 default.yaml/symbols.yaml 必须同时存在于用户目录，否则
	@# `default:key_binder` 解析失败 → schema config 构建失败 → **grammar(LM) 静默失效**。
	@for f in default.yaml symbols.yaml essay.txt; do \
		$(PYTHON) $(REPO)/scripts/rel_symlink.py $(TEST_DIR)/$$f $(LIBRIME_BIN)/$$f --quiet; \
	done
	@cp -f $(REPO)/data/gram/wanxiang-lts-zh-hans.gram $(TEST_DIR)/ 2>/dev/null || true
	@# LM 重排表（纯 Lua 的 n-gram 表，见 scripts/gen_lm_rerank.py）
	@# 运行时文件优先取 **git 跟踪的 dicts/**（新 clone 也有），没有再回退 data/gram/
	@# py_syllables.txt 是 lua/compose_filter.lua 判「混打」用的音节表（§4.83）
	@for f in lm_rerank.meta lm_rerank.bin compose_table.bin py_meta.txt py_syllables.txt; do \
		if [ -f $(DICTS)/$$f ]; then cp -f $(DICTS)/$$f $(TEST_DIR)/; \
		elif [ -f $(GRAM_DIR)/$$f ]; then cp -f $(GRAM_DIR)/$$f $(TEST_DIR)/; fi; \
	done
	@cp -f $(GRAM_DIR)/lm_rerank.tsv $(GRAM_DIR)/py_words.tsv \
		$(GRAM_DIR)/py_syllables.txt $(TEST_DIR)/ 2>/dev/null || true
	@# 先部署出 build/ 产物: 空 build/ 下首次 console 会撞维护竞态(陷阱 #2)
	@$(LIBRIME_BIN)/rime_deployer --build $(TEST_DIR) $(SHARED_DIR) \
		$(TEST_DIR)/build >/dev/null 2>&1 || true
	@mkdir -p $(TEST_DIR)/dicts; cp -f $(GRAM_DIR)/compose_table.bin $(GRAM_DIR)/lm_rerank.bin $(TEST_DIR)/dicts/ 2>/dev/null || true
	@echo "测试用户目录: $(TEST_DIR)"
	@echo "共享数据目录: $(SHARED_DIR)"

# --- 回归测试 ---------------------------------------------------------------
verify: test verify-wubi bench  ## 全链验收：契约 + 黄金 33 + 五笔能力 + 延迟门

verify-bundle: bundle      ## 交付包验收（**先按当前工作区重打包** → 解包→装到空目录→探针）
	@$(PYTHON) scripts/verify_bundle.py

verify-repro:      ## 复现性门：用当前语料重跑 dict 阶段，产物必须与仓库逐字一致（需本地 data/corpus）
	@bash scripts/refresh.sh --from dict
	@git diff --exit-code -- dicts/ data/gram/ \
	  && echo "✓ 产物可复现（与仓库一致）" \
	  || { echo "✗ 产物与仓库不一致：要么生成器/管线参数变了但没重出产物，要么语料有新增（后者应把新产物提交）"; exit 1; }

verify-wubi: env-test      ## 五笔能力验收（H11 五组 + 阈值，约 1 分钟；超阈 exit 1）
	@$(PYTHON) scripts/verify_wubi.py

bench: env-test            ## 输入延迟基准（性能回归门；超基线 1.5x 即 exit 1）
	@$(PYTHON) scripts/bench_typing.py

eval: env-test          ## 跑整句评测（160 句多来源；对比生产用的万象 gram 与自训 gram）
	@# 必须包含**生产用的万象 gram**：此前默认只比 essay/自训，导致「生产的 160 句成绩」
	@# 一直测不出来（HANDOFF 里 75/160 无法用 make eval 复现）——§4.83
	@$(PYTHON) scripts/eval_gram.py --cases 0 --sentences 160 --jobs $${EVAL_JOBS:-6} \
		--gram "万象=$$PWD/data/gram/wanxiang-lts-zh-hans.gram" \
		--gram "自训=$$PWD/data/gram/zh-hans-egret.gram"

lint:                     ## 结构与命名一致性检查（秒级，不跑引擎）
	@$(PYTHON) scripts/check_consistency.py
	@EGRET_ROOT=$(REPO) lua scripts/check_lm_table.lua
	@EGRET_ROOT=$(REPO) lua scripts/check_compose_table.lua

test: env-test lint
	$(PYTHON) scripts/regression_test.py
	test -z "$$(git -C $(REPO) status --porcelain user.yaml)" || \
		echo "⚠ 仓库 user.yaml 被回写污染, 请检查 (陷阱 #1)"

test-rebuild: env-test
	$(PYTHON) scripts/regression_test.py --rebuild --clean
	test -z "$$(git -C $(REPO) status --porcelain user.yaml)" || \
		echo "⚠ 仓库 user.yaml 被回写污染, 请检查 (陷阱 #1)"

# --- 词库生成与分档 ---------------------------------------------------------
gen:
	$(PYTHON) scripts/gen_wubi_py_unified_dicts.py

# 词典分档：core(≈2万词) / base(≈6.3万词, 默认) / full(≈78万词)
# 五笔码与拼音码同步分层，保证“拼音也能打全”。三档均通过黄金用例 20/20。
tiers:            ## 生成三档词表（不改当前档位）
	$(PYTHON) scripts/gen_dict_tiers.py

tier:             ## 切档: make tier TIER=core|base|full
	@test -n "$(TIER)" || { echo "用法: make tier TIER=core|base|full"; exit 1; }
	$(PYTHON) scripts/gen_dict_tiers.py --tier $(TIER)
	$(PYTHON) scripts/set_tier.py $(TIER)
	@echo "已切到 $(TIER) 档；重新部署: make deploy（或 make test-rebuild 本地验证）"

# C2 权重回归：用语料词频把词条权重压回 0-1000（与字库/LM 同尺度）
reweight:         ## 用语料词频重写词条权重（先跑 corpus-freq）
	$(PYTHON) scripts/reweight_from_corpus.py --dry-run
	@read -p "确认写入? [y/N] " a; [ "$$a" = y ] || exit 1
	$(PYTHON) scripts/reweight_from_corpus.py

# LM 评测：黄金 + 句子级（全拼还原）
eval-gram:        ## AB 评测各套 gram（默认比 essay-bgc vs 自训）
	$(PYTHON) scripts/eval_gram.py --cases 0 --sentences 100

# --- 部署到输入法 -----------------------------------------------------------
gram-lm:           ## 下载万象词级语言模型（~400MB；断点续传，已有则跳过）
	@mkdir -p "$(GRAM_DIR)"
	@if [ -f "$(GRAM_LM)" ]; then \
	  echo "已存在 $(GRAM_LM)（$$(du -h "$(GRAM_LM)" | cut -f1)）"; \
	else \
	  echo "下载 $(GRAM_LM_URL)"; \
	  curl -fL --retry 3 --retry-delay 2 -C - -o "$(GRAM_LM).part" "$(GRAM_LM_URL)" \
	    && mv -f "$(GRAM_LM).part" "$(GRAM_LM)" \
	    || { echo "✗ 下载失败：$(GRAM_LM_URL)"; echo "  国内网络可试：proxychains4 make gram-lm"; rm -f "$(GRAM_LM).part"; exit 1; }; \
	  echo "已下载 $(GRAM_LM)（$$(du -h "$(GRAM_LM)" | cut -f1)）"; \
	fi

deploy:            ## 按运行时清单装到输入法用户目录（TARGET=...；--link 软链；实体目录自动备份）
	@# 唯一部署引擎（清单来自 scripts/deploy_bundle.sh --list）；离线包 install.sh 走同一个脚本
	@# 语言模型（400MB，不随仓库分发）：缺了就自动下载（断点续传），引擎再负责软链
	@if [ ! -f "$(GRAM_LM)" ]; then echo "  语言模型缺失 → 自动下载（~400MB）…"; $(MAKE) -s gram-lm || true; fi
	@bash scripts/deploy_runtime.sh "$(REPO)" "$(TARGET_DIR)" --link

reload:            ## 目标机：重建 Rime build 并重启输入法（Linux=fcitx5 / macOS=Squirrel）
	bash scripts/reload_ime.sh "$(TARGET_DIR)" $(if $(NO_RESTART),--no-restart,)

# --- 语料管线（阶段 A~E）----------------------------------------------------
# 一键刷新：用 data/input 下最新语料增量刷新全部产物（抽取→清洗→词频→词典→gram→验证）
bundle:           ## 打出可拷到其它机器的运行时部署包 (dist/*.tar.gz；离线机器用)
	bash scripts/deploy_bundle.sh

refresh:          ## 一键刷新全部产物（增量，可直接重跑）
	bash scripts/refresh.sh

refresh-list:     ## 查看各阶段状态
	bash scripts/refresh.sh --list

# 投放：把语料丢进 data/input/（epub/md/html/纯文本混放均可）
# 抽取：按文件类型自动分派处理器（见 scripts/corpus/formats.py）
corpus-extract:   ## 增量抽取 input -> extract/（按类型自动识别）
	$(PYTHON) scripts/corpus/extract.py --jobs 3 --nice 15

corpus-dry-run:   ## 只看待处理清单（不改动任何文件）
	$(PYTHON) scripts/corpus/extract.py --dry-run --unknown-list

corpus-status:    ## 语料账本（篇数/字符/汉字/占用）
	$(PYTHON) scripts/corpus/status.py

# --- 其它 -------------------------------------------------------------------
paths:            ## 打印路径自检
	$(PYTHON) scripts/rime_paths.py

check:
	bash scripts/setup_env.sh check

clean-test:
	rm -rf $(TEST_DIR)/build $(TEST_DIR)/*.userdb \
		$(TEST_DIR)/egret_wubi.user.dict.txt $(TEST_DIR)/egret_wubi_py_script.user.dict.txt
	@echo "已清理 $(TEST_DIR) 的 build 与用户词典"
