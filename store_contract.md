# 核对过的 REAREye 商店契约

公开源码核对时间：2026-10-29。本文件是技术依据，功能可能随宿主更新变化。

## 脚本安装

[`RearStoreRepository.kt`](https://github.com/killerprojecte/REAREye/blob/dev/app/src/main/java/hk/uwu/reareye/repository/rearstore/RearStoreRepository.kt) 中安装卡片后调用 `installComponentScripts(context, detail.widgetId, assetBytes)`。它规范化商店 ID，在 ZIP 中查找 `scripts/`，把后续相对路径作为完整脚本项目安装。ZIP 根目录不能只放 main.lua，MAML 也不能继续指向旧的独立脚本项目。

[`ScriptProjectStore.kt`](https://github.com/killerprojecte/REAREye/blob/dev/app/src/main/java/hk/uwu/reareye/script/ScriptProjectStore.kt) 将组件目录映射为 `component:<id>` 项目，安装时替换整个脚本树。项目入口为 main.lua，require 与 readText 都以项目目录为根。

## 安装元数据

根 widget_info.json 由商店读取。business_setup 指定模板业务；card_setup 指定卡片名称和所属包，安装后生成卡片。未提供 card_setup 不能据此承诺用户可直接切换到新卡片。本包目标类型是普通 widget/card，不是 install_as_app，不输出 APK。

[`RearStoreScreen.kt`](https://github.com/killerprojecte/REAREye/blob/dev/app/src/main/java/hk/uwu/reareye/ui/screen/RearStoreScreen.kt) 的 buildPostInstallUri 替换 `{id}` 为商店条目 ID，`{business}` 为业务配置 ID，`{card}` 为卡片 ID。postinstall 为 content scheme 时使用 contentResolver.query；返回值可能进入宿主调试日志，必须只输出脱敏状态。

本包使用 `content://hk.uwu.reareye.script/component:{id}/bootstrap`，由宿主调用安装后的组件项目。MAML 路由则固定匹配拟提交 ID `bmw_i3_cloud`。必须对齐商店 ID，而不是根据仓库名猜组件项目目录。

## 发布与收录

[`NekoStash/submission`](https://github.com/NekoStash/submission) 要求仓库根 widget_info.json、合法小写字母数字_-的 Widget ID，并通过其 Issue 模板提交仓库根 URL。组件包作为 GitHub Release 附件供商店获取。元数据准备好不等于条目已收录；本次没有远程发布或提交 Issue。

用户指定的仓库为 https://github.com/Micromai01/BMW_SubSceen_Card，公开 main 分支在核对时只显示 README。不能声称该仓库已经有可下载的 v3.5 发行版。

当前 README 的表现形式参考 https://github.com/ghhccghk/Yadea_SubSceen_Card ，宝马脚本没有复用雅迪广播协议，也没有借用其 minVersion 99 作为未经验证的脚本最低版本号。
