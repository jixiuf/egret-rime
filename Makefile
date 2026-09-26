# 独立仓库部署: 把本仓库软链进 Rime 用户目录
# (macOS=Squirrel ~/Library/Rime; Linux fcitx5 见下方 TARGET)
UNAME := $(shell uname)

ifeq ($(UNAME), Linux)
    TARGET := $(HOME)/.local/share/fcitx5/rime/
else
    TARGET := $(HOME)/Library/Rime/
endif

.PHONY: deploy
deploy:
	mkdir -p $(TARGET)
	ln -sfn "$(CURDIR)/dicts" "$(TARGET)dicts"
	ln -sfn "$(CURDIR)/lua" "$(TARGET)lua"
	ln -sfn "$(CURDIR)/opencc" "$(TARGET)opencc"
	ln -sf "$(CURDIR)/"*.yaml "$(TARGET)"
# @if [ ! -f wanxiang-lts-zh-hans.gram  ]; then \
# 	wget -c https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram;\
# fi
# https://github.com/rimeinn/octagram-data/
#https://github.com/lotem/rime-octagram-data/releases/tag/20260712
# hant 为繁体字，hans 为简体字
# bg 表示 bigram，tg 表示 trigram
# c 表示字级，w 表示词级
# 如 wqhao 五笔wq: 你，+hao:好 -> 你好 就需要 char 级的才能实现
	@if [ ! -f zh-hans-t-essay-bgc.gram  ]; then \
		wget -c https://github.com/lotem/rime-octagram-data/releases/download/20260712/zh-hans-t-essay-bgc.gram;\
	fi
	ln -sf "$(CURDIR)/"*.gram "$(TARGET)"

	@echo "已部署到 $(TARGET) (重新部署/重启输入法后生效)"

.PHONY: test
test:
	python3 scripts/regression_test.py

.PHONY: test-rebuild
test-rebuild:
	python3 scripts/regression_test.py --rebuild --clean

.PHONY: gen
gen:
	python3 scripts/gen_wubi_py_unified_dicts.py
