# sub2api-bar

> 把 [sub2api](https://github.com/) 的账号配额搬到 macOS 菜单栏，一眼看见还剩多少。

[![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](#系统要求)
[![language](https://img.shields.io/badge/Swift-5.9%2B-orange)](#从源码构建)
[![license](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)

菜单栏上常驻一个环形进度 + 百分比，鼠标移上去是完整报表，点开是可操作的菜单。不进 Dock、不抢焦点、没有后台常驻进程以外的任何动静。

```
┌─────────────────────────────────────────────────────────┐
│  ◔ 7d  3%                       🔋  📶  🔍  9月14日 周日  │
└─────────────────────────────────────────────────────────┘
     ↑
     环形进度 + 当前窗口占用；悬停看全部，点击展开菜单
```

## 特性

- **多窗口配额** —— 5h、7d、7d Opus、7d Fable、7d Sonnet，菜单栏显示哪一个可选，也可以交给 `自动`（永远显示占用最高的那个）。
- **悬停即全貌** —— 用量窗口（占用 / 重置倒计时 / 花费）、今日用量、计费周期用量，一次给全，不用点开。
- **计费周期可切口径** —— 默认跟随 Claude 的 7 天滚动窗口，也可以按自然月的任意账单日切分。
- **按 HIG 画的界面** —— 菜单栏图标是模板图像，浅色/深色、菜单栏染色、失焦变浅、展开时反色全都跟着系统走；菜单用原生分节样式与语义色。
- **布局不跳动** —— 百分比宽度按两位数钉死，`9% → 10%` 时图标位置和整项宽度纹丝不动。
- **只读管理接口** —— 自动轮询只走读接口；会触发上游真实探测的强制刷新单独放在菜单里，手动才走。
- **配置是一个 JSON 文件** —— `~/.config/sub2api-quota/config.json`，权限 600，可以直接手改，改完点一下菜单栏即生效。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 Sonoma 或更高（菜单用到 `NSMenuItem.sectionHeader`） |
| 构建 | Xcode Command Line Tools（`xcode-select --install`），不需要完整 Xcode |
| 服务端 | 一个 sub2api 实例，以及它的**管理 API Key**（`admin-` 开头） |

## 安装

### Homebrew（推荐）

```bash
brew trust --formula marstechhan/sub2api-bar/sub2api-bar
brew tap marstechhan/sub2api-bar https://github.com/MarsTechHAN/sub2api-bar
brew install --HEAD sub2api-bar
```

在本机现编译 `main` 上的最新代码，不下载预编译产物。

> `brew trust` 是 Homebrew 7 加的一道闸：非官方 tap 里的 formula 默认不加载，且必须**在 `brew tap` 之前**信任，否则 tap 会以 `invalid syntax in tap!` 失败。Homebrew 6 及更早没有这一步，可以跳过。

装好之后把 app 链进「应用程序」，方便 Spotlight 启动与开机自启：

```bash
ln -sfn "$(brew --prefix sub2api-bar)/Sub2API Quota.app" /Applications/
open "/Applications/Sub2API Quota.app"
```

卸载：

```bash
brew uninstall sub2api-bar && brew untap marstechhan/sub2api-bar
```

### 从源码构建

```bash
git clone https://github.com/MarsTechHAN/sub2api-bar.git
cd sub2api-bar
./build.sh
open "build/Sub2API Quota.app"
```

`build.sh` 直接调 `swiftc` 编译 `Sources/*.swift` 并手工拼出 `.app`（含 `Info.plist` 与 ad-hoc 签名），没有 Xcode 工程、没有第三方依赖。装到系统里：

```bash
cp -R "build/Sub2API Quota.app" /Applications/
```

> **关于签名**：产物是 ad-hoc 签名的，不是 Apple 公证过的。从源码自己编的不会被 Gatekeeper 拦；如果是从别处拷贝来的 `.app`，首次打开需要在「系统设置 → 隐私与安全性」里放行。

## 配置

三种方式，改的是同一个文件。

**图形界面** —— 菜单栏图标 → `设置…`（`⌘,`），填服务地址和管理 API Key，可以先「测试连接」。

**命令行**

```bash
# Homebrew 安装的话，CLI 叫 sub2api-bar
sub2api-bar --endpoint https://sub2api.example.com --api-key admin-xxxxxxxx
sub2api-bar --accounts      # 列出服务上的账号
sub2api-bar --dump          # 用当前配置打一遍接口，把拿到的数据打出来
sub2api-bar --help
```

源码构建的话可执行文件在 `build/Sub2API Quota.app/Contents/MacOS/Sub2APIQuota`，参数一样。

**直接改文件** —— `~/.config/sub2api-quota/config.json`（权限 600）：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `endpoint` | `""` | sub2api 服务地址，结尾斜杠会自动去掉 |
| `api_key` | `""` | 管理 API Key，通过 `X-Api-Key` 头发送 |
| `account_id` | `0` | 监控哪个账号，`0` = 首次刷新时自动选 |
| `display_mode` | `"auto"` | `auto` / `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_fable` / `seven_day_sonnet` |
| `refresh_interval` | `60` | 轮询间隔（秒），最小 15 |
| `cycle_mode` | `"7d"` | `7d` 跟随 7 天滚动窗口，或 `month:N` 按每月 N 号 |
| `show_gauge` | `true` | 是否显示环形进度 |
| `show_label` | `true` | 是否显示窗口名（`7d` / `5h` / `7dF` …） |
| `title_gap` | `5.5` | 窗口名与百分比之间的间距（pt）。系统字体的普通空格约 3.58pt |
| `title_align` | `"right"` | 百分比在预留宽度里靠哪边。`right` 把富余空间放在窗口名和数字之间（数字按列对齐），`left` 放在最右边 |

手改完不用退出重开，点一下菜单栏图标就会重新读取。

## 使用

点开菜单栏图标：

- **用量窗口 / 今日用量 / 计费周期** —— 三段只读报表，和悬停提示的内容一致。
- **账号** —— 按平台分组列出服务上的账号，切换监控对象。
- **菜单栏显示** —— 选哪个窗口上菜单栏，以及是否显示环形进度 / 窗口名。
- **刷新间隔** —— 15 秒到 10 分钟。
- **计费周期口径** —— 跟随 7 天滚动窗口，或指定每月账单日。
- **立即刷新**（`⌘R`）/ **强制刷新**（`⇧⌘R`，会触发上游真实探测，别频繁用）/ **设置…**（`⌘,`）/ **退出**（`⌘Q`）。

## 工作原理

轮询 sub2api 的管理接口，全部在 `/api/v1` 下：

| 接口 | 用途 |
| --- | --- |
| `GET /admin/accounts` | 账号列表（也是「测试连接」用的） |
| `POST /admin/accounts/usage/batch` | 各配额窗口的占用与重置时间 |
| `POST /admin/accounts/today-stats/batch` | 今日请求数 / token / 花费 |
| `GET /admin/accounts/{id}/stats?days=N` | 历史按日统计，累加成计费周期用量 |

两处口径值得说明：

- **7 天滚动窗口的起点** = 该窗口的重置时间往前推 7 天。Claude / Codex 的额度就是这么滚的，所以「计费周期」默认跟着它，和额度重置时刻天然对齐。
- **周期用量是自然日累加的**。sub2api 的历史接口只有自然日粒度，周期起点不在 00:00 时结果会偏大，这种情况界面上会标成「近似」，不假装精确。

凭据存在 `~/.config/sub2api-quota/config.json`（0600），没有走钥匙串：这个 app 是本地 ad-hoc 签名的，每次重新编译签名都变，钥匙串会因为身份对不上而拒绝读取，反而更难用。

## 开发

```
Sources/
├── main.swift                    入口，命令行参数优先于界面
├── CLI.swift                     --endpoint / --api-key / --dump / --accounts
├── Settings.swift                配置读写（JSON, 0600）
├── APIClient.swift               sub2api 管理接口
├── Models.swift                  账号 / 用量窗口 / 统计
├── SnapshotLoader.swift          一次刷新拉齐所有数据
├── StatusItemController.swift    菜单栏项与菜单
├── MenuViews.swift               菜单里的自定义行视图
├── GaugeIcon.swift               菜单栏模板图标
├── SettingsWindowController.swift 设置窗口
├── Report.swift                  悬停提示 / 终端报表
├── Util.swift                    格式化与计费周期计算
└── Log.swift                     ~/.config/sub2api-quota/ 下的运行日志
```

```bash
./build.sh                                    # 编译 + 打包 + 签名
"build/Sub2API Quota.app/Contents/MacOS/Sub2APIQuota" --dump   # 不起界面，自检数据
```

## 许可证

[GPL-3.0](LICENSE)
