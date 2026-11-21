#!/bin/bash
unset BASH_ENV

SECONDS=0 # builtin bash timer

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

export DEVICE=r8q
export KBUILD_BUILD_USER="nihil"
export KBUILD_BUILD_HOST="aspire-dev"
export KBUILD_COMPILER_STRING="Snapdragon LLVM ARM Compiler 19.0.0"

PREBUILT_MODE=0

for arg in "$@"; do
    case "$arg" in
        -p|--prebuilt)
            PREBUILT_MODE=1
            ;;
        -h|--help)
            echo "Uso: ./build.sh [-p|--prebuilt]"
            echo "  -p, --prebuilt   Compila o kernel e exporta os arquivos prebuilt (Image, dtb, dtbo.img, headers) em out/prebuilt-kernel"
            echo "  (sem argumentos) Compila o kernel e gera o zip flashavel AnyKernel3"
            exit 0
            ;;
        *)
            ;;
    esac
done

# ===== AnyKernel3 =====
AK3_REPO="https://github.com/doubledashdot/AnyKernel3"
AK3_BRANCH="$DEVICE-ksu"

ZIPNAME="Orchestrator-$DEVICE-5.4-$(date "+%Y%m%d").zip"
TC_DIR="$(pwd)/tc/sdclang"
ln -sfn "$TC_DIR" "$(pwd)/tc/sdclang20" 2>/dev/null || true
TC_BIN="$TC_DIR/bin"
export PATH="$TC_BIN:$PATH"

if [ "$PREBUILT_MODE" -eq 1 ]; then
    DEFCONFIG="vendor/kona-vanadium_defconfig vendor/samsung/$DEVICE.config vendor/extra/no-ksu.config vendor/extra/sdclang.config"
else
    DEFCONFIG="vendor/kona-vanadium_defconfig vendor/samsung/$DEVICE.config vendor/extra/ksu.config vendor/extra/sdclang.config"
fi

OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
DTS_DIR="$BOOT_DIR/dts/vendor/qcom"
PREBUILT_DIR="$OUT_DIR/prebuilt-kernel"

if ! [ -d "$TC_DIR" ]; then
    echo -e "${YELLOW}Clang not found! Downloading...${NC}"
    mkdir -p "$TC_DIR"

    ASSET_URL=$(
        curl -fsSL https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest |
        jq -r '.assets[]
            | select(.name | endswith(".tar.zst"))
            | .browser_download_url' |
        head -n1
    )

    if [ -z "$ASSET_URL" ]; then
        echo -e "${RED}Failed to find latest release!${NC}"
        exit 1
    fi

    if ! curl -L "$ASSET_URL" | tar --zstd -x -C "$TC_DIR" --strip-components=1; then
        echo -e "${RED}Download failed!${NC}"
        exit 1
    fi

    echo -e "${GREEN}Clang ready!${NC}"
fi

mkdir -p out
echo -e "${YELLOW}building with: $DEFCONFIG${NC}"

make O=out ARCH=arm64 HOSTCC=/usr/bin/clang CC=clang $DEFCONFIG
make O=out ARCH=arm64 HOSTCC=/usr/bin/clang CC=clang olddefconfig

echo -e "\n${YELLOW}Starting compilation (Version: 5.4.233-Orchestrator/qgki+)...${NC}\n"

MAKE_ARGS=(
    -j$(nproc --all)
    O=out
    ARCH=arm64
    CC=clang
    HOSTCC=/usr/bin/clang
    HOSTCXX=/usr/bin/clang++
    LD=$TC_BIN/ld.lld
    AS=$TC_BIN/llvm-as
    AR=$TC_BIN/llvm-ar
    LLVM_AR=$TC_BIN/llvm-ar
    NM=$TC_BIN/llvm-nm
    LLVM_NM=$TC_BIN/llvm-nm
    OBJCOPY=$TC_BIN/llvm-objcopy
    OBJDUMP=$TC_BIN/llvm-objdump
    STRIP=$TC_BIN/llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    KCFLAGS="-Xclang -fexperimental-assignment-tracking=disabled -Wno-pointer-sign -Wno-default-const-init-field-unsafe -Wno-default-const-init-var-unsafe -Wno-undefined-optimized"
    LLVM=1
    LLVM_IAS=1
)

make "${MAKE_ARGS[@]}" dtbo.img
make "${MAKE_ARGS[@]}" Image
    
if [ -f "$BOOT_DIR/Image" ]; then
    echo -e "${GREEN}Kernel Image found!${NC}"
    
    if [ -d "$DTS_DIR" ]; then
        echo -e "${BLUE}Generating dtb from $DTS_DIR...${NC}"
        cat $(find "$DTS_DIR" -type f -name "*.dtb" | sort) > "$BOOT_DIR/dtb"
        
        if [ -f "$BOOT_DIR/dtb" ]; then
            echo -e "${GREEN}dtb generated successfully!${NC}"
        else
            echo -e "${RED}Failed to generate dtb! Check if dtbs were compiled.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}DTS directory not found. Compilation might be incomplete.${NC}"
        exit 1
    fi
else
    echo -e "\n${RED}Compilation failed! Image not found.${NC}"
    exit 1
fi

if [ "$PREBUILT_MODE" -eq 1 ]; then
    echo -e "\n${YELLOW}Modo prebuilt ativado! Preparando arquivos em $PREBUILT_DIR...${NC}\n"
    rm -rf "$PREBUILT_DIR"
    mkdir -p "$PREBUILT_DIR/kernel-headers"

    echo -e "${BLUE}Instalando kernel headers...${NC}"
    make "${MAKE_ARGS[@]}" INSTALL_HDR_PATH="$PREBUILT_DIR/kernel-headers" headers_install

    find "$PREBUILT_DIR/kernel-headers" \( -name "..install.cmd" -o -name ".install" \) -delete 2>/dev/null

    if [ -d "$PREBUILT_DIR/kernel-headers/include" ]; then
        cp -rn "$PREBUILT_DIR/kernel-headers/include/"* "$PREBUILT_DIR/kernel-headers/" 2>/dev/null || true
    fi

    echo -e "${BLUE}Copiando Image, dtb e dtbo.img...${NC}"
    cp "$BOOT_DIR/Image" "$PREBUILT_DIR/Image"
    cp "$BOOT_DIR/dtb" "$PREBUILT_DIR/dtb"
    cp "$BOOT_DIR/dtbo.img" "$PREBUILT_DIR/dtbo.img"

    echo -e "\n${GREEN}Arquivos prebuilt gerados com sucesso em $PREBUILT_DIR:${NC}"
    ls -la "$PREBUILT_DIR"
else
    rm -rf AnyKernel3
    echo "[*] Cloning AnyKernel3 for $DEVICE"
    git clone -q -b "$AK3_BRANCH" "$AK3_REPO" --depth=1 AnyKernel3 || exit 1

    echo -e "Preparing zip...\n"

    rm -rf *.zip
    cp "$BOOT_DIR/dtbo.img" AnyKernel3/dtbo.img
    cp "$BOOT_DIR/Image" AnyKernel3/Image
    cp "$BOOT_DIR/dtb" AnyKernel3/dtb

    cd AnyKernel3
    zip -r9 "../$ZIPNAME" * -x .git README.md *placeholder
    cd ..
fi

echo -e "\n${GREEN}SHA-256 Checksums:${NC}"
sha256sum "$BOOT_DIR/Image"
sha256sum "$BOOT_DIR/dtbo.img"
sha256sum "$BOOT_DIR/dtb"
if [ -f "$ZIPNAME" ]; then
    sha256sum "$ZIPNAME"
fi

echo -e "\n${GREEN}Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!${NC}"
if [ "$PREBUILT_MODE" -eq 1 ]; then
    echo -e "${GREEN}Prebuilt kernel salvo em: $PREBUILT_DIR${NC}"
else
    echo -e "${GREEN}Zip: $ZIPNAME${NC}"
fi
