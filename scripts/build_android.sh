#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Auto-detect Android Studio Java if JAVA_HOME is not set
if [ -z "$JAVA_HOME" ]; then
    if [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
        export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        export PATH="$JAVA_HOME/bin:$PATH"
    fi
fi

# Auto-detect Android SDK if ANDROID_HOME is not set
if [ -z "$ANDROID_HOME" ]; then
    if [ -d "$HOME/Library/Android/sdk" ]; then
        export ANDROID_HOME="$HOME/Library/Android/sdk"
        export PATH="$ANDROID_HOME/platform-tools:$PATH"
    fi
fi

# Auto-detect Android NDK if ANDROID_NDK_HOME is not set or invalid
if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    if [ -n "$ANDROID_NDK_ROOT" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
        export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
    elif [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/ndk" ]; then
        LATEST_NDK=$(find "$ANDROID_HOME/ndk" -maxdepth 1 -mindepth 1 | sort -V | tail -n1)
        if [ -n "$LATEST_NDK" ]; then
            export ANDROID_NDK_HOME="$LATEST_NDK"
        fi
    fi
fi
echo "Using ANDROID_NDK_HOME: ${ANDROID_NDK_HOME:-<unset>}"

echo "=== Building atv-android native library ==="

cd "$ROOT_DIR"

BUILD_MODE="${1:-release}"
KEYSTORE_PATH="${2:-$ROOT_DIR/Corvo_Development.p12}"
KEYSTORE_PASS="${3:-${MACOS_CERT_P12_PASSWORD:-corvo-developer}}"

if command -v cargo-ndk &> /dev/null; then
    echo "Found cargo-ndk, building arm64-v8a + armeabi-v7a release..."
    cargo ndk -t arm64-v8a -t armeabi-v7a -o "$ROOT_DIR/android-tv/app/src/main/jniLibs" build --release -p atv-android
else
    echo "cargo-ndk not found. Checking standard cargo build..."
    for TARGET in aarch64-linux-android armv7-linux-androideabi; do
        case "$TARGET" in
            aarch64-linux-android) ABI="arm64-v8a" ;;
            armv7-linux-androideabi) ABI="armeabi-v7a" ;;
        esac
        JNILIBS_DIR="$ROOT_DIR/android-tv/app/src/main/jniLibs/$ABI"
        mkdir -p "$JNILIBS_DIR"
        cargo build --target "$TARGET" --release -p atv-android
        cp "$ROOT_DIR/target/$TARGET/release/libatv_android.so" "$JNILIBS_DIR/"
    done
fi

echo "Native libraries copied to: $ROOT_DIR/android-tv/app/src/main/jniLibs/"

# Locate and run llvm-strip if present to ensure smallest possible .so
STRIP_BIN=""
if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    STRIP_BIN=$(find "$ANDROID_HOME/ndk" -name "llvm-strip" 2>/dev/null | head -n1 || true)
fi
if [ -z "$STRIP_BIN" ] && [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    STRIP_BIN=$(find "$ANDROID_NDK_HOME" -name "llvm-strip" 2>/dev/null | head -n1 || true)
fi
if [ -n "$STRIP_BIN" ] && [ -x "$STRIP_BIN" ]; then
    for SO in "$ROOT_DIR"/android-tv/app/src/main/jniLibs/*/libatv_android.so; do
        [ -f "$SO" ] || continue
        echo "Stripping symbols from $SO..."
        "$STRIP_BIN" --strip-all "$SO" || true
    done
fi

echo "=== Building Android TV APK ($BUILD_MODE) ==="
cd "$ROOT_DIR/android-tv"

if [ "$BUILD_MODE" = "release" ]; then
    ./gradlew assembleRelease
    
    UNSIGNED_APK="$ROOT_DIR/android-tv/app/build/outputs/apk/release/app-release-unsigned.apk"
    SIGNED_APK="$ROOT_DIR/android-tv/app/build/outputs/apk/release/FakeAtv-release.apk"
    
    if [ -f "$KEYSTORE_PATH" ]; then
        echo "🔏 Signing APK with keystore: $KEYSTORE_PATH..."
        # Locate apksigner from Android SDK
        APKSIGNER_BIN=""
        if [ -n "$ANDROID_HOME" ] && [ -d "$ANDROID_HOME/build-tools" ]; then
            APKSIGNER_BIN=$(find "$ANDROID_HOME/build-tools" -name apksigner | sort -V | tail -n1)
        fi
        
        if [ -n "$APKSIGNER_BIN" ] && [ -x "$APKSIGNER_BIN" ]; then
            "$APKSIGNER_BIN" sign \
                --ks "$KEYSTORE_PATH" \
                --ks-type PKCS12 \
                --ks-pass "pass:$KEYSTORE_PASS" \
                --out "$SIGNED_APK" \
                "$UNSIGNED_APK"
            
            echo "🔍 Verifying APK signature..."
            "$APKSIGNER_BIN" verify -v "$SIGNED_APK"
            echo "✅ Signed APK created at: $SIGNED_APK"
        else
            echo "⚠️ apksigner not found in ANDROID_HOME/build-tools. Left APK as unsigned: $UNSIGNED_APK"
        fi
    else
        echo "ℹ️ Keystore $KEYSTORE_PATH not found, keeping unsigned APK at $UNSIGNED_APK"
    fi
else
    ./gradlew assembleDebug
fi

echo "Done!"

