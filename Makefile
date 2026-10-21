.PHONY: build install clean verify help

help:
	@echo "  make build    编译 kext（无需 Xcode）"
	@echo "  make install  安装并验证收录（需 root）"
	@echo "  make verify   检查当前是否已加载"
	@echo "  make clean    清理构建产物"

build:
	./build.sh

install:
	sudo ./deploy.sh

verify:
	@kextstat | grep -i thunderbolt3unblocker || echo "未加载（需重启）"
	@system_profiler SPThunderboltDataType | grep -iA4 "Vendor Name" || true

clean:
	rm -rf build obj
