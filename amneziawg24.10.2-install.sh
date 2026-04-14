#!/bin/sh

#set -x

PKG_MANAGER=""
PKG_EXT=""

detect_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    else
        printf "\033[32;1mNo supported package manager found (apk/opkg).\033[0m\n"
        exit 1
    fi
}

pkg_update() {
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
    else
#        opkg update
    fi
}

is_pkg_installed() {
    pkg_name="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk info -e "$pkg_name" >/dev/null 2>&1
    else
        opkg list-installed 2>/dev/null | grep -q "^${pkg_name} "
    fi
}

install_local_pkg() {
    pkg_file="$1"
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

get_pkgarch() {
    PKGARCH_UBUS=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.arch' 2>/dev/null)
    if [ -n "$PKGARCH_UBUS" ]; then
        echo "$PKGARCH_UBUS"
        return
    fi

    if command -v opkg >/dev/null 2>&1; then
        opkg print-architecture | awk 'BEGIN {max=0} {if ($3 > max) {max = $3; arch = $2}} END {print arch}'
        return
    fi

    if [ -f /etc/openwrt_release ]; then
        PKGARCH_RELEASE=$(grep "^DISTRIB_ARCH='" /etc/openwrt_release | cut -d"'" -f2)
        if [ -n "$PKGARCH_RELEASE" ]; then
            echo "$PKGARCH_RELEASE"
            return
        fi
    fi

    if command -v apk >/dev/null 2>&1; then
        apk --print-arch
        return
    fi

    uname -m
}

download_package() {
    pkg_base_name="$1"
    pkg_postfix_base="$2"
    awg_dir="$3"
    base_url="$4"

    preferred_file="${pkg_base_name}${pkg_postfix_base}.${PKG_EXT}"
    preferred_url="${base_url}${preferred_file}"
    if wget -q -O "$awg_dir/$preferred_file" "$preferred_url" && [ -s "$awg_dir/$preferred_file" ]; then
        echo "$preferred_file"
        return 0
    fi
    rm -f "$awg_dir/$preferred_file"

    if [ "$PKG_EXT" = "apk" ]; then
        fallback_ext="ipk"
    else
        fallback_ext="apk"
    fi

    fallback_file="${pkg_base_name}${pkg_postfix_base}.${fallback_ext}"
    fallback_url="${base_url}${fallback_file}"
    if wget -q -O "$awg_dir/$fallback_file" "$fallback_url" && [ -s "$awg_dir/$fallback_file" ]; then
        echo "$fallback_file"
        return 0
    fi
    rm -f "$awg_dir/$fallback_file"

    return 1
}

#Репозиторий OpenWRT должен быть доступен для установки зависимостей пакета kmod-amneziawg
check_repo() {
    printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
    if [ "$PKG_MANAGER" = "apk" ]; then
        pkg_update >/dev/null 2>&1 || \
            { printf "\033[32;1mapk failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n"; exit 1; }
    else
        pkg_update | grep -q "Failed to download" && \
            printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1
    fi
}

install_awg_packages() {
    # Получение pkgarch с наибольшим приоритетом
    PKGARCH=$(get_pkgarch)

    TARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 1)
    SUBTARGET=$(ubus call system board | jsonfilter -e '@.release.target' | cut -d '/' -f 2)
    VERSION=$(ubus call system board | jsonfilter -e '@.release.version')
    PKGPOSTFIX_BASE="_v${VERSION}_${PKGARCH}_${TARGET}_${SUBTARGET}"
    # BASE_URL="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/"
    BASE_URL="https://github.com/yanjore/awg-openwrt/releases/download/"

    # Определяем версию AWG протокола (2.0 для OpenWRT >= 23.05.6 и >= 24.10.3)
    AWG_VERSION="1.0"
    MAJOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 1)
    MINOR_VERSION=$(echo "$VERSION" | cut -d '.' -f 2)
    PATCH_VERSION=$(echo "$VERSION" | cut -d '.' -f 3)

    if [ "$MAJOR_VERSION" -gt 24 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -gt 10 ] || \
       [ "$MAJOR_VERSION" -eq 24 -a "$MINOR_VERSION" -eq 10 -a "$PATCH_VERSION" -ge 2 ] || \
       [ "$MAJOR_VERSION" -eq 23 -a "$MINOR_VERSION" -eq 5 -a "$PATCH_VERSION" -ge 6 ]; then
        AWG_VERSION="2.0"
        LUCI_PACKAGE_NAME="luci-proto-amneziawg"
    else
        LUCI_PACKAGE_NAME="luci-app-amneziawg"
    fi

    printf "\033[32;1mDetected AWG version: $AWG_VERSION\033[0m\n"

    AWG_DIR="/tmp/amneziawg"
    mkdir -p "$AWG_DIR"

    if is_pkg_installed "kmod-amneziawg"; then
        echo "kmod-amneziawg already installed"
    else
        KMOD_AMNEZIAWG_FILENAME=$(download_package "kmod-amneziawg" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg file downloaded successfully"
        else
            echo "Error downloading kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$KMOD_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "kmod-amneziawg installed successfully"
        else
            echo "Error installing kmod-amneziawg. Please, install kmod-amneziawg manually and run the script again"
            exit 1
        fi
    fi

    if is_pkg_installed "amneziawg-tools"; then
        echo "amneziawg-tools already installed"
    else
        AMNEZIAWG_TOOLS_FILENAME=$(download_package "amneziawg-tools" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "amneziawg-tools file downloaded successfully"
        else
            echo "Error downloading amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$AMNEZIAWG_TOOLS_FILENAME"

        if [ $? -eq 0 ]; then
            echo "amneziawg-tools installed successfully"
        else
            echo "Error installing amneziawg-tools. Please, install amneziawg-tools manually and run the script again"
            exit 1
        fi
    fi

    # Проверяем оба возможных названия пакета
    if is_pkg_installed "luci-proto-amneziawg" || is_pkg_installed "luci-app-amneziawg"; then
        echo "$LUCI_PACKAGE_NAME already installed"
    else
        LUCI_AMNEZIAWG_FILENAME=$(download_package "$LUCI_PACKAGE_NAME" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
        if [ $? -eq 0 ]; then
            echo "$LUCI_PACKAGE_NAME file downloaded successfully"
        else
            echo "Error downloading $LUCI_PACKAGE_NAME. Please, install $LUCI_PACKAGE_NAME manually and run the script again"
            exit 1
        fi

        install_local_pkg "$AWG_DIR/$LUCI_AMNEZIAWG_FILENAME"

        if [ $? -eq 0 ]; then
            echo "$LUCI_PACKAGE_NAME installed successfully"
        else
            echo "Error installing $LUCI_PACKAGE_NAME. Please, install $LUCI_PACKAGE_NAME manually and run the script again"
            exit 1
        fi
    fi

    # Устанавливаем русскую локализацию только для AWG 2.0
    if [ "$AWG_VERSION" = "2.0" ]; then
        printf "\033[32;1mУстанавливаем пакет с русской локализацией? Install Russian language pack? (y/n) [n]: \033[0m\n"
        read INSTALL_RU_LANG
        INSTALL_RU_LANG=${INSTALL_RU_LANG:-n}

        if [ "$INSTALL_RU_LANG" = "y" ] || [ "$INSTALL_RU_LANG" = "Y" ]; then
            if is_pkg_installed "luci-i18n-amneziawg-ru"; then
                echo "luci-i18n-amneziawg-ru already installed"
            else
                LUCI_I18N_AMNEZIAWG_RU_FILENAME=$(download_package "luci-i18n-amneziawg-ru" "$PKGPOSTFIX_BASE" "$AWG_DIR" "${BASE_URL}v${VERSION}/")
                if [ $? -eq 0 ]; then
                    echo "luci-i18n-amneziawg-ru file downloaded successfully"
                    install_local_pkg "$AWG_DIR/$LUCI_I18N_AMNEZIAWG_RU_FILENAME"
                    if [ $? -eq 0 ]; then
                        echo "luci-i18n-amneziawg-ru installed successfully"
                    else
                        echo "Warning: Error installing luci-i18n-amneziawg-ru (non-critical)"
                    fi
                else
                    echo "Warning: Russian localization not available for this version/platform (non-critical)"
                fi
            fi
        else
            printf "\033[32;1mSkipping Russian language pack installation.\033[0m\n"
        fi
    fi

    rm -rf "$AWG_DIR"
}

detect_package_manager
check_repo

install_awg_packages

printf "\033[32;1mSkipping amneziawg interface configuration.\033[0m\n"
