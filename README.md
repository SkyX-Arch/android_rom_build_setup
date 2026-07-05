# 🛠️ Android ROM Build Environment Setup Script

<p align="center">

<img src="https://img.shields.io/badge/Type-Build%20Automation-blue?style=for-the-badge">
<img src="https://img.shields.io/badge/Target-AOSP%20Build%20Env-green?style=for-the-badge">
<img src="https://img.shields.io/badge/Platform-Linux-orange?style=for-the-badge">

</p>

---

## 📌 Overview

This repository contains an **automated build environment preparation script** for AOSP-based ROM development.

The script is designed to simplify and standardize the initial setup process required for building custom Android ROMs.

---

## ⚙️ What it does

The script performs the following steps automatically:

1. Detects your Linux distribution and package manager  
2. Installs required build dependencies for AOSP/ROM compilation  
3. Installs or updates the `repo` tool  
4. Initializes the ROM source (`repo init`)  
5. Downloads and places a `local_manifest.xml` into `.repo/local_manifests`  
6. Synchronizes source code using `repo sync`  
7. Prints final build environment readiness status  

---

## 📦 Usage

Make the script executable and run it:

```bash id="run1"
chmod +x prepare_build.sh
./prepare_build.sh
```
Alternatively:

```bash 
bash prepare_build.sh
```

## ⚙️ Configuration

The script includes a CONFIG section where you can define:

- ROM manifest URL
- Branch name
- Local manifest source
- Build directory
- Sync options

You can also override values using environment variables before running the script.

## 🧩 Intended use

This script is intended for:

- AOSP-based ROM development
- [crDroid](https://github.com/SkyX-Arch/crdroid-ota) / LineageOS / Other ROM build 
- [Device trees such as Xiaomi 12T (plato)](https://github.com/SkyX-Arch/android_device_xiaomi_plato)
- [MediaTek MT6895 platform builds](https://github.com/SkyX-Arch/android_device_xiaomi_mt6895-common)

## ⚠️ Notes
The script does NOT build the ROM itself
It only prepares and synchronizes the build environment
Some steps may require manual intervention depending on distro
Internet connection is required for repo sync
Use at your own risk

## 🚧 Status

Actively maintained as a ROM development utility script and may be updated as build system requirements evolve across Android versions.
