# 从系统精选集移除壁纸

基于上游 `72bf625befdb5e9e16d52c663e123f9fbc8ec7bf`。

## 上游情况

[PR #126](https://github.com/huamidev/GestaltX/pull/126) 已合并，解决的是删除本地导入包时被系统卸载校验阻止的问题。它将垃圾桶改为仅删除 App 内的导入包，保留系统壁纸及安装记录。检查时其余开放 PR 为翻译和文档修改，没有发现系统卸载入口。

本补丁使用已有 `removeWallpaper` 实现，补齐系统卸载界面和已归档安装记录的列表。

## 使用

1. 将手机切换到其他壁纸。
2. 打开 GestaltX → 壁纸设置 → **已安装到系统**。
3. 找到对应壁纸包，选择 **从系统移除**，核对包名后确认。
4. 若精选集仍显示旧缩略图，重新启动 PosterBoard 或使用 App 原有注销功能后再查看。

原垃圾桶仍仅删除本地导入包。导入包已删除的壁纸也会通过保留的 `WallpaperInstallations` 记录列出。不扫描或猜测未知壁纸的归属；已丢失安装记录的素材不在本补丁的处理范围内。

系统移除仍使用上游的设备绑定、路径及文件哈希检查，只处理该包记录的目录。移除后请求图库刷新；刷新失败时保留安装记录，可修复错误后重试。

## 验证

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 tests/run_wallpaper_removal.py
python3 tests/LocalizationTests.py
git diff --check
```

文件系统回归使用实际 Store 和临时目录，覆盖本地删除后找回安装记录、同 UUID 多次安装合并显示、系统移除、设备或内容不匹配时拒绝移除、刷新失败后重试，以及其他壁纸保持不变。依赖固定为项目原有 ZIPFoundation 0.9.20。

本机已通过上述回归和本地化检查，也已使用 iOS 18.5 SDK 对修改的 SwiftUI 界面及关联 Store 做类型检查（仅系统访问桥接替换为空实现）。没有连接 iPhone 实测，也未生成可安装 IPA。

## 构建及覆盖安装

完整 App 保持上游的构建条件：iOS 部署版本 26.0、可用的对应 Xcode/SDK，以及 `Native/DeviceConsole/build/GXDeviceConsole.xcframework`。按仓库 `.github/workflows/build.yml` 先构建原生依赖，再运行 `.github/scripts/build-ipa.sh`。本机 Xcode 16.4 只有 iOS 18.5 SDK，读取构建设置时即报错：无法打开上游格式版本 110 的项目。因此未完成完整 App 构建，不能将局部类型检查视为 IPA 构建成功。

安装修改版时应保留原 App 数据及身份，使用原签名工具覆盖安装，保留分享扩展和可用的共同 App Group。不要先卸载原 App，否则可能丢失用于精准卸载壁纸的安装记录。若设备绑定校验失败，补丁会保留记录并显示错误，不绕过校验。
