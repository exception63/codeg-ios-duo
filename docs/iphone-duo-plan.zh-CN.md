# Codeg iOS · iPhone Duo 适配方案（第一步：现状与改法）

> 2026-10-28 · 分支 `iphone-duo`（基于上游 main `e2d75f9`，1.0.1）· 业务代码未改动
> 环境：Xcode 27.2（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）、模拟器「iPhone Duo · Codeg」（`701B3C12-B879-4B2F-9071-9FB42CC17A1C`，iOS 27.2 24B91016s）

---

## 0. 结论

1. **原版不改代码就能在 Duo 上跑**：Xcode 27.2 能编过，只有 9 条与适配无关的旧警告（`resignFirstResponder()` 返回值没用上、`Text +` 被弃用）。代码里没用 `UIScreen.main`，也没按机型或方向判断布局。外屏把标签栏竖着放到右侧，半折时系统会把两栏分界对齐到折痕，这两件事都是系统自己处理的。
2. **最大的问题是合上和打开时状态会丢**。`RootView` 按 `horizontalSizeClass` 在两套外壳之间切换：外屏是 compact，走底部 `TabView`；内屏横放、竖放、半折都是 regular，走三栏 `NavigationSplitView`。两套外壳的导航状态在 `AppModel` 里各存一份，互不同步。所以一开合，会话会丢、会错（显示另一套外壳上次的会话），滚动位置回到底部，Terminal 被拆掉重开。
3. **内屏上的 Folder 详情和 Terminal 只能待在中栏**（340–520pt），内屏竖放时中栏又被系统收起，Terminal 就看不见了。
4. 改法分三步：统一导航状态 → 把详情和终端的状态提到外壳外面 → 调整列宽和一些细节。第 5 节有每一步的做法和验收方式。

## 1. 怎么测的

- **本地假服务端**：Studio 上没有 codeg 桌面版或 server，Docker 也没开。所以写了一个只监听 `127.0.0.1:3180` 的 Python 假服务端：`runtime/mock/codeg_mock.py`。它用 `token` 文件里随机生成的测试令牌，提供会话列表、会话详情（一条 36 个 turn 的长会话，用来测滚动）、文件夹、文件、git 日志/状态，以及真 PTY 的 Terminal（`/ws/events` 的 `terminal://output` 帧）。文件夹指向本地 clone，因此 Files/Commits/Terminal 显示的都是真实内容。没接 ACP 实时事件流。
- **操作**：用 `dhctl` 切换姿势和旋转，用 `simdriver` 和 iOS Simulator MCP 点击、滑动、输入，用 `simctl io … --display=primary|primary-1` 给两块屏分别截图。
- **截图**：在 `runtime/duo-2026-10-28/shots/` 下，共 54 张，每个状态都有 `-outer` 和 `-inner` 两张。`runtime/` 已写进 `.git/info/exclude`，不进 git。下文的「截图 NN」指 `NN-*-outer.png` / `NN-*-inner.png` 这一对文件。

## 2. 各状态表现

| 状态 | 尺寸类 | 外壳 | 表现 | 截图 |
|---|---|---|---|---|
| 合上 · 外屏竖 (466×678pt) | compact | `TabView` | 正常。标签栏被系统竖着放在右侧状态条下面，导航按钮也竖排在右侧 | 01、02、16 |
| 合上 · 外屏横 | compact | `TabView` | 正常。导航按钮竖排在摄像头那一侧，标签栏收起成一个当前页图标 | 09、21 |
| 打开 · 内屏横 (951×669pt，扣掉右侧状态条约 876pt) | regular | 三栏 | 首次展开时**侧栏以浮层盖住中栏**，要手动收起。之后中栏约 360pt，详情约 550pt | 03、04、05 |
| 打开 · 内屏竖 (669×951pt) | regular | 三栏 | 系统自动只显示详情（detailOnly），左上按钮能叫出侧栏和列表 | 06、19 |
| 半折 | regular | 三栏 | 两栏分界被系统对齐到折痕（中栏变宽、详情变窄）。会话和滚动位置都保留 | 08、20 |
| 内屏横 ⇄ 竖 | regular → regular | 不切换 | 会话和滚动位置**都保留** | 06b → 07 |
| 合上 ⇄ 打开 | compact ⇄ regular | **切换外壳** | 会话丢失或错位，滚动位置回到底部，Terminal 重开 | 见 P0 |

## 3. 问题清单

### P0-1 合上和打开时会话丢失或错位

- 截图 02 → 03：在外屏打开「适配 iPhone Duo 内屏三栏布局」并滚到第 16 步，展开后右栏显示 **Select a Session**，会话没了。
- 截图 11 → 12：在内屏打开「Docker 镜像瘦身」，合上后外屏显示的是**更早在外屏打开的另一条会话**「适配 iPhone Duo…」。
- 截图 17：在外屏的 Folders → codeg-ios → Terminal 页展开，内屏右栏显示的是内屏上次选中的会话，Folders 的上下文丢了。
- 原因：
  - compact 用 `AppModel.selectedTab` + `paths[tab]`（`CodegiOS/App/AppModel.swift:44-45`）。
  - regular 用 `sidebarSection` / `contentPath` / `selectedConversationID` / `pendingNewSession`（`AppModel.swift:32-37`）。
  - `open(_:)`（`AppModel.swift:87`）只写当前外壳的那一份。
  - `RootView.swift:50-52` 在尺寸类变化时只更新 `isCompact`，没有在两份状态之间同步。

### P0-2 切换外壳时会话详情被重建，滚动位置回到底部

- 截图 06b → 10：在内屏滚到第 14–15 轮，合上再打开后回到了第 18 轮（底部）。截图 02 → 09 也一样，从第 16 步变回底部。
- 原因：两套外壳各自创建 `SessionDetailView`，它的 `@State model`（`SessionDetailView.swift:20`）跟着视图一起销毁，`TranscriptView` 又用 `.defaultScrollAnchor(.bottom)`（`TranscriptView.swift:271`），所以每次都从底部开始。
- 推断（未实测）：输入框里没发出去的草稿、附件、事件流连接也会跟着重建。

### P0-3 Terminal 在内屏受限，切换时被拆掉

- 截图 16 → 17 → 21：外屏 Terminal 里有输出，展开后终端页没了。再合上时，外屏回到 Folder 详情，但标签停在 **Files**，之前的输出也没了。假服务端日志显示：2 次 `terminal_spawn`，2 次 `terminal_kill`，其中一次的 kill 发生在之后的姿势切换时，晚了一步。
- 截图 18：内屏横放时，Folder 详情（Files/Changes/Commits/Terminal）被塞进中栏，宽约 380pt。右侧约 550pt 的详情栏却显示一条无关的会话。
- 截图 19：转到内屏竖放后，系统收起中栏，**终端完全看不到**，只剩那条无关会话。
- 原因：
  - `TerminalSession` 是 `ProjectDetailView` 的 `@State`（`ProjectDetailView.swift:85`），视图销毁时 deinit 就杀掉 PTY。
  - regular 下 `.project` 路由只进中栏（`AppModel.open` 的 `.project` 分支 → `contentPath`），中栏宽度被限制为 `navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)`（`RootView.swift:265`）。

### P1-4 首次展开时侧栏浮层盖住中栏

- 截图 03：`columnVisibility` 初值是 `.all`（`RootView.swift:18`）。260 + 340 + 详情放不下内屏横放约 876pt 的可用宽度，系统就把侧栏改成浮层，盖住会话列表。要点「Hide Sidebar」才恢复正常（截图 04）。

### P1-5 内屏只显示详情时正文行太长

- 截图 17、22：详情占满约 820pt 时，一行中文接近 40 个字，输入框也拉得很长。读起来累，和对话类 App 的通常做法不一致。

### P2（小问题）

- **P2-6** 外屏 Terminal 的键盘工具条（esc/ctrl/方向键）右端被侧边标签栏遮住一截（截图 16）。工具条本身能横向滑动，只是看起来像被切掉了。
- **P2-7**「滚到底部」的圆按钮压在消息气泡上（截图 07、22），iPhone 上原本就这样，内屏上更明显。
- **P2-8** regular 没有单独的 Search 入口。`AppModel.select(tab:)` 把 `.search` 映射到会话列表，会话列表的本地过滤框（`.searchable`）在内屏截图里没出现，应该是被收进了工具栏。待确认。2Future 的经验是固定用 `.navigationBarDrawer(displayMode: .always)`。
- **P2-9** 侧栏标题「Mock S…」被截断（截图 03），服务器名稍长一点就显示不全。

### 已经正常的（不用改）

- 外屏标签栏、导航按钮的位置由系统处理（截图 01）。
- 半折对齐折痕（截图 08）。
- 键盘弹出时输入框跟着上移（截图 22）。
- regular 内部旋转不丢状态（截图 07）。
- 不涉及 `UIScreen.main`、idiom 或方向判断。

## 4. 设计原则

1. **合上和打开时停在同一个地方**：同一条会话、同一个滚动位置、同一个终端，三次开合都一样。这是苹果的硬性要求，也是 Duo 体验的核心。
2. **外屏保持 iPhone 原样**，只在 regular 宽度上加东西，改动尽量限制在外壳和路由这一层。
3. **少分叉**：通用的修正（状态同步、视图模型上提）对 iPad 分屏也有用，写法要能提回上游；Duo 专属的部分（Bundle ID、名字、图标）放在配置里。

## 5. 改法

### M1 统一导航状态（解决 P0-1、P1-4）

- 在 `AppModel` 里加一份不依赖外壳的「当前位置」，比如 `focus: Route?`（当前的会话、新任务或文件夹）加上当前所在的分区（chats/projects/activity/search/settings）。`open(_:)`、深链、列表点击都先写这一份，再由外壳读出自己的形态。
- 在 `RootView` 的 `.onChange(of: horizontalSizeClass)` 里调用 `model.adapt(toCompact:)`：
  - **compact → regular**：取当前标签页 `paths[selectedTab]` 的最后一个路由。`.conversation`/`.newSession` 映射为 `selectedConversationID`/`pendingNewSession`，标签页映射为 `sidebarSection`，`.project` 映射见 M2。
  - **regular → compact**：用 `sidebarSection` 加详情选中项，生成 `selectedTab` 和 `paths[tab] = [根以下的路由]`。
- 要避开的坑（之前在别的 App 上踩过）：
  - 外壳切换后，导航栈要先立好根，**下一拍**再推入详情，比如 `Task { @MainActor in … }`。否则在内屏选中、合上后，详情页可能没有返回键。
  - 同一位置的 `NavigationStack(path:)` 不能换成不绑 path 的栈，否则会断言崩溃。
  - 合上后至少等 5 秒再截图验收。
- 侧栏显隐按可用宽度决定：`.onGeometryChange(for: Bool.self) { $0.size.width >= 1000 }`，够宽用 `.all`，否则用 `.doubleColumn`。内屏横放默认两栏，竖放让系统自己收成 detailOnly。用户手动改过之后，以用户为准。
- 验收：在外屏打开会话 → 展开 → 合上；在内屏换一条会话 → 合上 → 打开。每一步都停在同一条会话上（覆盖截图 03、12、17 这三种场景）。

### M2 把详情和终端的状态提到外壳外面（解决 P0-2、P0-3）

- **会话详情**：在 AppModel 层加一个 `SessionDetailViewModel` 缓存（按 `server|conversationID` 作 key，只保留最近的几条，比如 3 条）。两套外壳用同一个实例，事件流、草稿、附件跟着一起保留。
- **滚动位置**：`TranscriptView` 改用 `.scrollPosition(id:)` 绑定到缓存模型里的锚点（turn id）。只有锚点为空时才退回 `.defaultScrollAnchor(.bottom)`。用户在底部时继续跟随新消息，不在底部时恢复到原来的位置。
- **Terminal**：`TerminalSession` 也提到 AppModel 层，按文件夹 id 缓存，只在用户主动关闭、换服务器或 App 退出时才 kill，开合不再重开 shell。顺便让 Files/Changes/Commits/Terminal 的当前标签也跟着文件夹保存。
- **Folder 详情放进详情栏**：regular 下 `.project` 路由改为占用 detail 列，中栏仍是文件夹列表。这样 Terminal 在内屏横放时约有 550pt 宽，竖放时 detailOnly 也能看到。
- 验收：
  - 在内屏滚到中间 → 合上 → 打开：仍是原来那一轮。
  - 在外屏 Terminal 里跑 `ls` → 展开 → 合上：输出还在。假服务端日志里 `terminal_spawn` 只出现 1 次。

### M3 细节（P1-5、P2）

- 会话正文和输入框限制在 760pt 宽、居中显示，底色照样铺满（`.frame(maxWidth: 760).frame(maxWidth: .infinity)`）。
- Terminal 键盘工具条的尾部边距按安全区算，或者在末尾加渐隐提示可以滑动。
- regular 的会话过滤框固定显示（`.navigationBarDrawer(displayMode: .always)`），或在侧栏加一行 Search。
- 侧栏标题允许两行或缩小字号。「滚到底部」按钮避开气泡。
- 每个里程碑做完，都用同一套脚本把第 2 节的表格重新截一遍，和这次的截图逐张对照。

### 先不做

- Duo 专属的多窗口（`UIApplicationSupportsMultipleScenes` 已经开着）、拖放、折痕两侧的双窗格对话，等 M1–M3 稳定以后再说。
- 分屏（Split View）模式：内屏宽度变成 compact 时应退回单栏。M1 的状态同步本身就能覆盖这种情况，但目前还没有自动化测试。

## 6. Bundle ID、名称和签名

| 项 | 官方 | 我们的版本（建议） | 说明 |
|---|---|---|---|
| Bundle ID | `app.codeg.ios` | `com.exception63.codeg.duo` | 和自研 App 的前缀一致（如 `com.exception63.airouter.phone`），能和官方版同时装在一台手机上 |
| 显示名 | Codeg | Codeg Duo | 避免和官方版混淆 |
| URL scheme | `codeg://` | 新增 `codegduo://`，代码里两个都认 | 两个 App 都注册 `codeg://` 时，系统随机交给其中一个 |
| 图标 | 官方图标 | 换一版（加上折叠屏标记或换颜色） | Apache-2.0 不授权商标；自用也最好一眼分得清 |
| Keychain service | `com.codeg.ios.server-token` | 不用改 | 没有 access group，各 App 的钥匙串天然隔离 |
| Team | 空（`Signing.local.xcconfig` 自填） | `C5BH6BHB9Q` | 写在 `Config/Signing.local.xcconfig`（已在 .gitignore 里） |
| 版本号 | 1.0.1 (2) | `MARKETING_VERSION` 不变，`CURRENT_PROJECT_VERSION` 用 `2.1`、`2.2`… | 不占官方的编号，方便看出基于哪个上游版本 |

- **实际做法（已落地）**：`project.yml` 里的 Bundle ID、显示名、URL scheme 改成变量 `$(CODEG_BUNDLE_ID)`、`$(CODEG_DISPLAY_NAME)`、`$(CODEG_URL_SCHEME)`。Duo 版的值写在随分支提交的 `Config/Identity.xcconfig` 里，由 `Config/Signing.xcconfig` include 进来。这样换一台 Mac 构建，身份也不会变；上游更新时，`project.yml` 只有这几行可能冲突。Team 仍写在本地的 `Signing.local.xcconfig` 里（已被 git 忽略），和上游的约定一致。深链方面，`Route.urlSchemes` 同时认 `codeg` 和 `codegduo`。
- **真机**：主人的 iPhone Duo（`00008160-000E49093E800036`）已经登记在团队 C5BH6BHB9Q 里。在 Studio 上用 `-allowProvisioningUpdates` 签名，然后按 `iphone-duo-adapt` skill 里「装到真机」那一节，经 MacBook 用 `devicectl` 安装。新 Bundle ID 第一次签名时，Xcode 会自动建 App ID 和描述文件。
- **许可证**：保留 `LICENSE`、`NOTICE`，在 `NOTICE` 或 README 里加一句「本版本由 exception63 修改，增加了 iPhone Duo 适配」。改过的文件里不能删原作者的版权声明。只要不上架 App Store，就不涉及审核或商标问题。如果以后要公开发布，再单独评估。

## 7. 要不要 fork 到自己的 GitHub

建议**要**，原因有两个：一是分支需要备份，二是要在两台 Mac 之间同步（真机安装要经过 MacBook）。具体做法有两种，需要主人选：

| 方式 | 优点 | 缺点 |
|---|---|---|
| **A. 私有仓库 `exception63/codeg-ios-duo`（推荐先用这个）** | 不公开。`origin` 指向自己的仓库，`upstream` 指向 xintaofei，跟进上游方便 | 往上游提 PR 时，还得另开一个公开 fork |
| B. GitHub 上直接 Fork（公开） | 一键创建，提 PR 最方便 | 公开 fork 不能设为私有；截图、内部文档也会跟着公开 |

- **已定（2026-10-28）：用方式 A。** 私有仓库 `exception63/codeg-ios-duo` 已经建好，`main` 和 `iphone-duo` 都推上去了。本地的 remote 是这样配的：`origin` 仍指向 xintaofei 上游，因为 `../repo-status.sh` 是拿 `origin` 判断「是否落后上游」的；新加的 `duo` 指向自己的私有仓库，`iphone-duo` 跟踪 `duo/iphone-duo`。
- 本地仓库的约定照旧：`main` 只跟上游，`iphone-duo` 放我们的改动。跟进上游时先 `git fetch origin`，再在 `iphone-duo` 上 `git rebase origin/main`，然后 `git push duo`。
- M1、M2 里的通用修正（开合状态同步、视图模型上提）对官方 iPad 版也有用。稳定以后，可以拆成干净的 PR 提给上游（这时再开公开 fork）。如果上游接受了，我们的分支就只剩配置差异。
- Bundle ID 已定为 `com.exception63.codeg.duo`（第 6 节），在 M1 之前作为单独一个提交改进配置。

## 8. 这次没覆盖的

- 真实的 codeg-server 和实时 ACP 事件流（运行中的会话、审批卡片、`conversation_linked`）：假服务端没有实现，到 M2 还要用真服务端再测一遍。
- 真机，以及分屏（Split View）、Settings sheet、Activity、新建任务流程在内屏上的表现。
- 中文系统语言下的界面（这次模拟器是英文界面，会话内容是中文）。
- 草稿在切换外壳时是否丢失：从代码推断会丢，没有实测。
