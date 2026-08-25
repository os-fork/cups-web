# CUPS Web 开发者指南

本文档面向开发者，介绍项目架构、API、开发流程与扩展方式。用户文档请参阅 [README.md](README.md)。

> 📚 **深度文档**：原理说明、故障案例与历史决策已移至 [docs/](docs/README.md)，本文件只保留可快速扫读的规则与契约。

## 📦 项目概述

- **项目定位**：基于 CUPS 的 Web 打印管理工具，前后端分离
- **技术栈**：Go 1.26（后端）+ Vue 3（前端）+ SQLite（存储）+ IPP（打印协议）
- **部署形态**：单二进制（前端 `go:embed`）连接外部 CUPS；**单容器（AIO）Docker 镜像**（`cupsd` + `cups-web` 同容器，内置 LibreOffice + Java 21 + OFD 转换器 + Ghostscript + 打印驱动生态）

> ⚠️ **历史形态提示**：仓库曾经是「cups 镜像 + cups-web 镜像」双容器（`cups/` 目录），已在合并提交里删除。现在只有根目录的一份 `Dockerfile` / `entrypoint.sh`，构建脚本在 `scripts/build/`、驱动脚本在 `scripts/driver/`。

## 🛠️ 技术栈

### 后端

| 组件 | 说明 |
| --- | --- |
| Go 1.26 | 见 `go.mod` |
| `gorilla/mux` | HTTP 路由 |
| `gorilla/securecookie` | 会话管理 |
| `modernc.org/sqlite` | 纯 Go SQLite，无 CGO |
| `OpenPrinting/goipp` | IPP 协议 |
| `rsc.io/pdf` + `phpdave11/gofpdf` | PDF 解析 / 生成 |
| `golang.org/x/image/draw` | 大图下采样（CatmullRom） |
| `golang.org/x/crypto/bcrypt` | 密码哈希 |

### 前端

| 组件 | 说明 |
| --- | --- |
| Vue 3.5 + Vue Router | hash 模式 |
| Vite 7 | 构建 |
| `@nuxt/ui` v4 + Tailwind CSS v4 | UI / 样式 |
| `pdfjs-dist` | 预览（PDF 生成由后端 `/api/convert` 负责） |
| Bun（本地）/ npm（CI + Docker） | 包管理。npm 用于覆盖 `linux/arm/v7`（Bun 不支持 32-bit ARM） |

### 外部依赖

CUPS（IPP 通信）、LibreOffice（Office → PDF）、Java 21 + `ofd-converter.jar`（OFD → PDF）、Ghostscript（PDF 标准化）、`dpkg`/`apt-get`（运行时驱动安装）。

> 各依赖的坑位说明（LibreOffice 可写 HOME、gs 字体破坏性改造、runtime 无 `dpkg-dev`）见 [docs/architecture.md](docs/architecture.md)。

## 📁 项目结构

```text
cups-web/
├── cmd/server/                    # 后端主程序
│   ├── main.go                    # 入口与路由注册
│   ├── app.go                     # 全局变量
│   ├── bootstrap.go               # 默认 admin 初始化
│   ├── auth_handlers.go           # 登录 / 登出 / session / csrf
│   ├── login_limiter.go           # 登录失败限流
│   ├── admin_handlers.go          # 管理员：用户 / 设置 / 清理
│   ├── user_handlers.go           # /api/me
│   ├── print_handlers.go          # /api/print（主打印入口）
│   ├── print_records_handlers.go  # 打印记录查询 / 下载 / 重打
│   ├── printer_info_handler.go    # 打印机属性查询
│   ├── convert_handler.go         # /api/convert
│   ├── convert_utils.go           # LibreOffice / OFD 转换工具
│   ├── compose_handler.go         # /api/compose（多页拼版）
│   ├── estimate_handler.go        # /api/estimate（预估页数）
│   ├── driver_handlers.go         # /api/admin/drivers/* + 后台任务
│   ├── driver_registry.go         # 驱动注册表
│   ├── file_utils.go              # 文件保存 / 类型识别 / 页数
│   ├── pdf_utils.go               # 图片 / 文本 → PDF
│   ├── pdf_compose.go             # 多页拼版
│   ├── pdf_reorder.go             # 页序重排 + 测试
│   ├── watermark.go               # 水印
│   ├── pdf_normalize.go           # PDF 标准化管线
│   ├── fonts.go                   # 中文字体加载
│   ├── maintenance.go             # 后台维护任务
│   └── version.go                 # 构建期版本号
├── internal/
│   ├── auth/session.go            # securecookie 会话 + CSRF
│   ├── middleware/                 # csrf / security 中间件
│   ├── ipp/                       # IPP 客户端 + URI 校验
│   ├── server/static.go           # 静态资源嵌入（SPA fallback）
│   └── store/                     # 数据层（users / prints / settings）
├── frontend/                      # Vue 3 前端（go:embed dist）
├── ofd-converter/                 # Java OFD → PDF
├── scripts/
│   ├── build/install-cups.sh      # 源码编译 CUPS
│   └── driver/                    # 驱动管理命令 + 安装脚本 + capture-debs.sh（apt 钩子）
├── docker-fonts/                  # 构建期字体与 gs/fontconfig 配置
├── entrypoint.sh                  # AIO 容器启动脚本
├── Dockerfile                     # 五阶段构建
├── docker-compose.yml             # 单服务 AIO
└── Makefile                       # 构建脚本
```

## 🔌 HTTP API

所有接口以 `/api` 为前缀。除登录/登出/csrf/session 外均需 `RequireSession` + `ValidateCSRF`；管理员接口再叠加 `RequireAdmin`。

> **CSRF 约定**：登录成功后下发 `csrf_token` Cookie（非 HttpOnly）；前端非 GET 请求带 `X-CSRF-Token` 头。

### 公开接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/login` | 登录 |
| POST | `/api/logout` | 登出 |
| GET | `/api/csrf` | 刷新 csrf token |
| GET | `/api/session` | 查询会话 |
| GET | `/api/version` | 构建版本号 |

### 已登录用户接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/me` | 当前用户信息 |
| GET | `/api/printers` | 列出打印机 |
| GET | `/api/printer-info?uri=<uri>` | 打印机属性 |
| POST | `/api/estimate` | 估算页数 |
| POST | `/api/convert` | 文档 → PDF（单文件 `file` / 多图 `files`） |
| POST | `/api/print` | 提交打印 |
| POST | `/api/compose` | 多页拼版 |
| GET | `/api/print-records` | 打印记录 |
| GET | `/api/print-records/{id}/file` | 下载原始文件 |
| POST | `/api/print-records/{id}/reprint` | 重打参数预填 |

#### `/api/printers` 返回形状

每项：`name` / `uri` / `info` / `location` / `makeAndModel`。`info` 即 CUPS Web 界面里的「描述」（`printer-info`），前端下拉靠它区分同型号队列（issue #101）。

- `ipp.ListPrinters` 优先走 IPP `CUPS-Get-Printers`（只点名 4 个 `requested-attributes`，否则每台机器回上百个属性）；操作被拒或对端不是 CUPS 时退回抓 `/printers` HTML 页面，此时 `info`/`location`/`makeAndModel` 为空串。
- 🚫 必须遍历 `rsp.Groups` 里的 `TagPrinterGroup`：`goipp` 的 `Message.Printer` 只是被压平的第一组，直接用它会在多队列时静默只返回一台。
- 🚫 URI 一律按 `CUPS_HOST` + 队列名拼，**不要**用响应里的 `printer-uri-supported` —— 那是 cupsd 自报的主机名，容器/跨网段场景下浏览器与服务端未必解析得到。
- CUPS 建队列不带 `-D` 时 `printer-info` 默认等于队列名，前端 `printerLabel()` 会在两者相同时省略描述，不重复显示。

### 管理员接口（`/api/admin/*`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET/POST | `/api/admin/users` | 用户列表 / 创建 |
| PUT/DELETE | `/api/admin/users/{id}` | 更新 / 删除（`admin` 禁止） |
| GET | `/api/admin/print-records` | 全站记录 |
| GET/PUT | `/api/admin/settings` | 系统设置 |
| POST | `/api/admin/cleanup` | 手动清理 |
| GET | `/api/admin/drivers` | 驱动列表 + 状态 |
| POST | `/api/admin/drivers/install` | **异步**安装，`202` + `jobId` |
| POST | `/api/admin/drivers/remove` | **异步**卸载，`202` + `jobId` |
| GET | `/api/admin/drivers/detect` | 扫描打印机推荐驱动 |
| GET | `/api/admin/drivers/ppds` | 候选 PPD 列表（`?deviceUri=&deviceId=&manufacturer=&model=&limit=8`） |
| POST | `/api/admin/drivers/upload` | 上传 `.ppd` / `.deb`（**同步**，64MB 上限） |
| POST | `/api/admin/drivers/setup` | **异步**一键设置，`202` + `jobId` |
| GET | `/api/admin/drivers/jobs/{id}` | 轮询任务状态 |

#### 驱动异步任务要点

- `install` / `remove` / `setup` **必须异步**（编译型驱动耗时可达十几分钟，全局 `WriteTimeout=120s` 会 kill 同步进程）。handler 立刻 `202` + `jobId`，命令跑在 `context.Background()` goroutine（硬超时 30min），前端轮询 `jobs/{id}`。
- **单飞**：同一时刻只允许一个驱动任务（apt/dpkg 全局锁），已有任务时返回 `409` + 正在跑的 `jobId`。
- 任务只存内存，保留 1 小时，进程重启即丢。

> 异步模型的完整设计理由与请求/响应形状见 [docs/driver-management.md](docs/driver-management.md#异步任务模型driver_handlersgo)。

`drivers[]` 每项是 `DriverStatus`：`name` / `displayName` / `description` / `arch` / `needCompile` / `installed` / `installedAt` / `installedArch` / `supported` / `hasScript`。`installed` 以 `manifest.txt` 是否存在为唯一判据。

`customDebs[]` 每项是 `CustomDebPackage`：`filename` / `installedAt` / `installedArch` / `sizeBytes`。纯信息性条目。

### `/api/print` 表单字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `file` | file | 待打印文件 |
| `printer` | string | 打印机 URI |
| `duplex` | `"true"` / `"false"` | 双面 |
| `color` | `"true"` / `"false"` | 彩色 |
| `copies` | int | 份数 |
| `orientation` | `portrait` / `landscape` | 方向 |
| `paper_size` | `A4` / `A3` / `5inch`…`10inch` | 纸张尺寸 |
| `paper_type` | `plain` / `photo` / … / `auto` | 纸张类型 |
| `media_source` | string | 进纸盒（`auto` 不发送） |
| `print_scaling` | `auto` / `auto-fit` / `fit` / `fill` / `none` / 纯数字 `10`–`400` | 缩放；纯数字＝自定义百分比 |
| `page_range` | string | 页码范围 |
| `page_set` | `all` / `odd` / `even` | 页面子集（`all` 不发送） |
| `mirror` | `"true"` / `"false"` | 镜像 |
| `number_up` | `1`–`16` | N-up（`1` 不发送） |
| `number_up_layout` | `lrtb` / `rltb` / `tblr` / `tbrl` | N-up 排布 |
| `page_border` | `single` / `none` | N-up 边框 |

## 🗄️ 数据库

SQLite，`WAL` + `foreign_keys`；迁移在 `store.go::migrate()` 中用幂等 SQL + `addColumnIfMissing` 增量加列。

### `users`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER PK | 自增 |
| `username` | TEXT UNIQUE | 登录名 |
| `password_hash` | TEXT | bcrypt |
| `role` | TEXT | `admin` / `user` |
| `protected` | INTEGER | `1` = 受保护 |
| `contact_name` / `phone` / `email` | TEXT | 联系信息 |
| `created_at` / `updated_at` | TEXT | RFC3339 UTC |

### `print_jobs`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | INTEGER PK | 自增 |
| `user_id` | INTEGER FK | 提交者 |
| `printer_uri` / `filename` / `stored_path` | TEXT | 打印机 / 文件 |
| `pages` | INTEGER | 页数 |
| `job_id` | TEXT | IPP Job ID |
| `status` | TEXT | `queued` / `printed` |
| `is_duplex` / `is_color` / `mirror` | INTEGER | 布尔参数 |
| `copies` / `number_up` | INTEGER | 数值参数 |
| `orientation` / `paper_size` / `paper_type` / `media_source` | TEXT | 纸张参数 |
| `print_scaling` / `page_range` / `page_set` | TEXT | 页面参数 |
| `watermark_text` | TEXT | 水印 |
| `number_up_layout` / `page_border` | TEXT | N-up 参数 |
| `created_at` | TEXT | RFC3339 UTC |

> 除 `is_duplex` / `is_color` 外，其余打印参数列为 Issue #68 新增（完整参数快照落库，供「重新打印」预填）。`page_set` 存用户原始选择（`even-reverse` 等），不是重排后的值。

### `settings`

KV 表。当前键：`retention_days`（`0` = 永久）、`session_hash_key` / `session_block_key`。

## 🔐 认证与安全

1. **启动**：`auth.SetupSecureCookie` 从 settings 读取/生成密钥
2. **登录**：写 `session`（HttpOnly，加密+签名）+ `csrf_token`（非 HttpOnly）
3. **鉴权链**：`RequireSession` → `RequireAdmin`（管理员）→ `ValidateCSRF`（非 GET）
4. **登出**：两条 cookie `MaxAge=-1`
5. **默认管理员**：`bootstrap.go` 保证 `admin/admin` 存在且 `protected=1`；`Username == "admin"` 判定保护（禁止改名/改角色/删除）

## 🖨️ 打印流水

`printHandler` 流程：接收 multipart → 落盘 `uploads/YYYYMMDD/` → 类型识别 & 转换 → 页数统计 → 插入 `queued` 记录 → IPP 提交 → 回写 `printed`。

- `pdf` → `normalizePDF`（gs → LibreOffice → passthrough）
- `office` → LibreOffice `--convert-to pdf`
- `ofd` → `java -jar /ofd-converter.jar`
- `image` → `gofpdf`（大图先下采样到 3000px）
- `text` → `gofpdf` + 内嵌中文字体

> ⚠️ 标准化管线只解决 CUPS 老驱动兼容性问题，gs 会破坏空壳 CJK 字体导致 pdf.js 预览错位。管线原理与 cidfmap 机制见 [docs/pdf-pipeline.md](docs/pdf-pipeline.md)。

### 自定义百分比缩放（`pdf_scale.go`）

`print_scaling` 为纯数字时走 `resolveCustomScaling`：gs 预缩放 PDF 内容 → 发给 CUPS 的 `print-scaling` 换成 `none`。
打印与重打（`reprintHandler`）两条路径都必须调用它。

- 🚫 **纯数字绝不能透传给 IPP**：`print-scaling` 是 keyword，`"40"` 不是合法取值。gs 失败/非 PDF 时退回空串（打印机默认），不是原样下发。
- 🚫 gs 缩放**不要**用 `-dFIXEDMEDIA` + 固定 `-dDEVICEWIDTHPOINTS`：横向页会被塞进纵向纸并偏移。现在的 `Install` 过程逐页读 `currentpagedevice /PageSize`，纸张尺寸原样保留。
- ⚠️ `-sOutputFile` 必须排在 `-f` **之前**——`-f` 之后的参数会被 gs 当成输入文件名，放末尾会直接报 `requires an output file`（Issue #98 的根因）。
- 前端预览用等比 CSS transform 同步这个百分比（`PrintPreview.vue` / `PdfCanvas.vue`），其余缩放模式交给 CUPS，预览不模拟。

## 🧹 维护任务

`maintenance.go` 每小时：读 `retention_days`（`0` 跳过）→ 删过期 `print_jobs` + 文件 → `VACUUM` + `wal_checkpoint`。管理员可 `POST /api/admin/cleanup` 手动触发。

## 🧩 驱动管理

相关文件：`driver_handlers.go`、`driver_registry.go`、`scripts/driver/*.sh`、`DriversView.vue`。

### 目录约定

| 路径 | 内容 |
| --- | --- |
| `/opt/cups-drivers/scripts/install-<name>.sh` | 安装脚本（构建期 COPY，不执行） |
| `/usr/local/bin/{driver-install,driver-list,driver-remove,restore-drivers}` | 管理命令 |
| `/opt/cups-drivers/libexec/capture-debs` | apt `DPkg::Pre-Install-Pkgs` 钩子（归档 apt 要装的 `.deb`） |
| `/opt/cups-drivers/baseline-packages.txt` | **构建期**生成的镜像自带包名快照（镜像层，**不在挂载卷内**） |
| `/opt/cups-drivers/data/<driver>/manifest.txt` | 文件清单 = **"已安装"唯一标记**（纯路径列表，包级模式下可能为空文件） |
| `/opt/cups-drivers/data/<driver>/packages.txt` | 存在即包级/混合模式。`<pkg> <version> <arch> <相对路径>` |
| `/opt/cups-drivers/data/<driver>/packages/*.deb` | 归档的 `.deb` 原件 |
| `/opt/cups-drivers/data/<driver>/metadata.txt` | `driver=` / `installed_at=` / `file_count=` / `arch=` / `manifest_version=` / `restore_mode=` / `package_count=` / `package_bytes=` |
| `/opt/cups-drivers/data/<driver>/<绝对路径镜像>` | 文件级产物副本 |
| `/opt/cups-drivers/data/custom-ppd/` | 上传 `.ppd`（写 manifest，可恢复） |
| `/opt/cups-drivers/data/custom-deb/packages/` | 上传 `.deb`（写 `packages.txt`，**重启自动重装**） |

`docker-compose.yml` 把 `./.drivers` 挂到 `/opt/cups-drivers/data`。**不挂卷 = 重启丢驱动。**

### 两条持久化通道（按驱动来源分流）

| 通道 | 适用 | 恢复 | 卸载 |
| --- | --- | --- | --- |
| **包级** | dpkg 包来源（`escpr2`(deb) / `canon-ufr2` / `konica-bizhub` / `epson-cn` / `gutenprint` / `custom-deb`） | `dpkg -i` 归档的 `.deb` | `apt-get purge`（dry-run 校验后）或 `dpkg -P --force-depends` |
| **文件级** | 非包来源（`canon-capt` / `hp-laserjet1020` / `sharp` / `foo2zjs-firmware` / `custom-ppd` / `escpr2`(源码分支)） | 按 manifest `cp -aT` | 按 manifest `rm -f` |

**为什么必须分流**：厂商 deb 普遍把产物装在 `/opt/<vendor>/`（Epson escpr2 的 298 个文件全在 `/opt`、Konica 的 filter 真身在 `/opt/km`）、`/usr/bin`（Canon UFR II 的渲染引擎 `cnrsdrvufr2`）、`/usr/share/<vendor>/`（gutenprint 的 370 个机型 XML、Canon 的 356 个 ICC），这些全在文件级路径白名单之外 —— 只靠文件级快照会得到空 manifest（`exit 1`，但文件其实已进容器）或残缺快照（UI 显示"已安装"而重启后驱动失效）。

`.deb` 原件的捕获有四层，前面命中就不用后面：apt 钩子（`capture-debs`，含全部传递依赖）→ 厂商脚本用 `DRIVER_PKG_DIR` 主动交接 → `/var/cache/apt/archives/` 打捞 → `apt-get download`。

> 🚫 `capture-debs` **必须永远 `exit 0`** —— `DPkg::Pre-Install-Pkgs` 返回非零会让 apt 中止**整个安装事务**。
>
> 🚫 厂商脚本的交接行必须 `|| true` 且不新增 `trap`，以免破坏"退出码 0/3/其他"和"只允许一个 EXIT trap"两条约定。

### 退出码约定

| 退出码 | 含义 | 行为 |
| --- | --- | --- |
| `0` | 成功 | 写 manifest |
| `3` | 架构不支持 | 不写 manifest，`exit 3` |
| 其他非零 | 真失败 | 不写 manifest，透传 |

**退出码 0 但文件与包归档同时为空才判失败**（拒绝写 manifest）。只要归档到了 `.deb`，即使所有文件都落在白名单外也算成功 —— 那种驱动照样能完整恢复。

### 架构探测

统一用 `dpkg --print-architecture`（**不要用 `dpkg-architecture`**，runtime 无 `dpkg-dev`）。Go 侧 `currentDebArch()` 映射 `GOARCH` → Debian 命名。multiarch 用 `detect_multiarch_libdir()`（glob `/usr/lib/*-linux-gnu*`，拿不到返回空串）。

### manifest 白名单速查

**ALLOW**：`/usr/lib/cups`、`/usr/share/cups`、`/usr/share/ppd`、`/usr/share/foomatic`、`/lib/firmware`、`/usr/lib/firmware`、`/usr/lib/<multiarch>`。

**DENY**：`/usr/bin/*`、`/usr/sbin/*`、`/bin/*`、`/sbin/*`、`/usr/local/{bin,sbin}/*`、`/etc/*`、`/var/*`、`/usr/include/*`、`/opt/cups-drivers/*`、`/tmp/*`、`/usr/share/{doc,man,locale,info}/*`、`/usr/share/cups/doc-root/*`、`*/pkgconfig/*`、`*.a`、`*.o`、`*.la`。

> ⚠️ **白名单在 `driver-install.sh` / `driver-remove.sh` / `restore-drivers.sh` 三处各有一份，必须永久保留全部三份**——remove/restore 侧是给存量被污染快照兜底的。🚫 不要因为 install 侧已过滤就删掉另外两处。详见 [docs/driver-management.md](docs/driver-management.md#-manifest-白名单为什么必须存在且三处都要有)。

### baseline 归属守卫（路径白名单的结构性补丁）

路径白名单有个**按路径分不开**的盲区：multiarch 目录（`/usr/lib/<triplet>`）既是驱动共享库的家、也是系统库的家。厂商 deb 的依赖被 apt 解析时会把无关系统库拖进来（老 `install-epson-cn.sh` 的 `apt-get -f install` 会拉进整套 Qt5/X11/GL —— 那只是 GUI 工具的依赖），它们正好落在白名单**内** → 被当成驱动产物写进 manifest → `driver-remove` 逐条 `rm` 就把系统库删了，`restore-drivers` 每次开机还用旧副本覆盖回去。

按**包属主**就分得干干净净：构建期把当时已安装的全部包名存进 `baseline-packages.txt`，三个脚本据此把"镜像自带包拥有的文件"一律排除（install 侧不记录，remove 侧不删，restore 侧不覆盖）。

实现要点：包名读进 bash 关联数组做 O(1) 判断（避免对两千多个 `.list` 文件各 fork 一次 grep）→ 只 `cat` baseline 包自己的 `/var/lib/dpkg/info/*.list`（multiarch 包的清单名是 `<pkg>:<arch>.list`，比对前要去掉 `:arch`）→ 与 manifest 求一次 `comm -12` 交集，之后逐条查是 O(1)。

> ⚠️ 这份守卫同样**三处各有一份**，理由与三份路径白名单相同。
>
> ⚠️ `baseline-packages.txt` 必须留在**镜像层**且生成于**所有 apt 安装之后**。放进 `/opt/cups-drivers/data` 会被 volume 挂载覆盖，守卫就降级成"只做路径白名单"。
>
> 🚫 **CUPS 自身的包绝不能进驱动快照**（`driver-install.sh` 的 `PKG_NAME_DENY_PATTERNS` 里列了 `cups` / `cups-core-drivers` / `cups-ppdc` / `libcups*` 等）。本镜像的 CUPS 是源码编译的（2.4.19，overlay tar 解包进 `/usr`），apt 侧只装了 `cups-daemon` / `cups-client` / `cups-filters`，**故意没有 `cups` 元包**。某些驱动包（`printer-driver-gutenprint`、Konica 的 deb）硬依赖 `cups` 元包，一旦让 apt 去满足就会装上 Debian 的 `cups-core-drivers` —— 那里面正是 `/usr/lib/cups/backend/{usb,socket,lpd,...}` 和一批 filter，**直接覆盖源码编译的同名文件**。实测 Konica 那条路径会让 564 个 CUPS 自身的文件被算进驱动快照。各 `install-*.sh` 用 `dpkg -i --force-depends` 从根上避免，DENY 再兜一层。

### AIO 编译脚本约定

> ⚠️ 编译型脚本**只允许一个 `trap _cleanup EXIT`**（bash 同信号只保留最后注册的 handler）。AIO 模式下只 `apt-get clean`，**绝不 `rm -rf /var/lib/apt/lists/*`**。详见 [docs/driver-management.md](docs/driver-management.md#-aio-编译脚本的单一-exit-trap约定)。

### 上传自定义驱动

- **`.ppd`**：校验 → 装到 `/usr/share/cups/model/custom/` → 写 manifest（可恢复）
- **`.deb`**：`dpkg -i`（失败补依赖后**必须再 `dpkg -i` 一次**）→ 归档到 `custom-deb/packages/` **并登记 `packages.txt`** → 容器启动时由 `restore-drivers` 幂等 `dpkg -i` 自动重装。仍**不写 manifest**（文件级恢复对 `.deb` 无意义，真正的安装动作在 maintainer script 里）
  - 存量只归档未登记的 `.deb` 会被 restore 按 glob **自动收养**，无需用户操作
  - 装不上的坏包会每次开机重试 → 出口是删掉宿主 `./.drivers/custom-deb/packages/` 下的对应文件
- 🔐 上传 `.deb` = 容器内 root RCE（dpkg maintainer script）。接口受三重鉴权保护，**管理员密码等同容器 root 凭据**
- 大小上限必须用 `http.MaxBytesReader`（`ParseMultipartForm(n)` 的 `n` 是 maxMemory 不是 body 上限）

> 上传机制完整说明见 [docs/driver-management.md](docs/driver-management.md#上传自定义驱动)。

### `lpinfo` 检测与一键设置

- 用 `lpinfo -l -v` **长格式**（短格式无厂商型号）；按 caps 加 `--timeout`/`--include-schemes`；独立超时 context（不挂 `r.Context()`）
- 型号优先级（修正）：`req.Manufacturer/Model`（lpinfo make-and-model，最可信）→ `device-id` MFG/MDL → URI 路径。🚫 不要把 URI 解析排最前（usb URI 的厂商常是裸 "HP" 甚至 "Unknown"）
- PPD 匹配走**打分引擎**（`ppd_match.go` 纯函数 + `ppd_query.go` 副作用层）：型号归一化 → 分层 tier 打分 → 来源偏好（custom > vendor > hplip > everywhere > foomatic > gutenprint > generic）→ cups-driverd 指纹加分 → 稳定排序 Top-N
- `GET /api/admin/drivers/ppds` 返回候选列表（不走后台 job，不占单飞锁，并发闸 4）
- `setup` 三态决策树：显式 `ppdUri` > `everywhere`（driverless）> 自动 Top-1 > **报错**（绝不静默建 raw）
- ⚠️ **`lpadmin` 不传 `-m` 建的是 raw 队列（无 PPD），不是 IPP Everywhere。** 真正的 driverless 要显式 `-m everywhere`。raw 队列拿不到 PPD 选项 → `/api/printer-info` 的 `mediaSourceSupported` 为空 → 前端进纸盒下拉消失
- 队列名去重（`uniquePrinterName`，`-2`…`-50` 后缀）；同 device-uri 已有队列时拒绝覆盖
- `lpadmin` 后验证（`lpstat -p` + `lpoptions -l`），PPD 未生效时 `isNew` 队列回滚 `lpadmin -x`

> 解析细节与历史翻车见 [docs/driver-management.md](docs/driver-management.md#lpinfo-检测格式假设与型号解析优先级)。

## 🚀 容器启动流程（`entrypoint.sh`）

1. `restore-drivers`（恢复驱动快照：先包级 `dpkg -i` 归档的 `.deb`，再文件级 `cp -a`）
2. CUPS 管理员用户 + tzdata
3. CUPS 配置还原（空卷时从 `/etc/cups-bak/` 复制）+ **对存量卷幂等补** `ssl/` 目录与 `ReadyPaperSizes`
4. HP 1020 PPD Letter → A4 修补（issue #48）
5. HP host-based 固件上传（后台）
6. dbus + avahi + ipp-usb（后台，允许失败）
7. cupsd + watchdog
8. 等 cupsd 就绪（`lpstat -r`，30 × 1s）
9. HP 1020 队列 `media-default=A4`（后台）
10. `exec /cups-web`（PID 1）

> ⚠️ cupsd 必须在 watchdog 子 shell **内部前台**启动（`wait` 只能等自己的子进程，否则 127 重启风暴）。🚫 不要把 `cupsd -f` 挪到子 shell 外面。
>
> ⚠️ `restore-drivers` 必须永远 `exit 0`（驱动恢复是尽力而为，不能阻塞启动，否则用户连 Web UI 都进不去无法自救）。它现在会跑 `dpkg -i`，因此必须 `DEBIAN_FRONTEND=noninteractive` + `--force-confold` + `timeout` + 临时 `policy-rc.d`（详见 docs）。
>
> ⚠️ **第 3 步的两条补丁必须在 `if [ ! -f cupsd.conf ]` 之外**：那个 if 只看 `cupsd.conf` 一个文件，存量 `./.etc` 卷里只要有它，整块还原就被跳过，新基线里加的东西存量用户永远拿不到。
>
> 🚫 **`lpadmin -o media=` 设的是 `media-default`，不是 `media-ready`。** iPhone AirPrint 面板的纸张**列表**读 `media-ready`，而 CUPS 的 `media-ready` 只由 cupsd.conf 的 `ReadyPaperSizes` ∩ PPD 尺寸决定（`scheduler/printers.c` 里 `load_ppd` 是唯一写入点），跟 `media-default` 无关。第 9 步只负责"面板默认勾选 A4"，issue #82 的真正修法是 `ReadyPaperSizes A4,A3,A5,A6,EnvDL`（值用 **PPD 尺寸名**，不是 PWG 名 `iso_a4_210x297mm`）。不配它时 cupsd 按 locale 兜底成 `Letter,Legal,Tabloid,4x6,Env10`（容器无 `LANG` → locale 为 C → 走 Letter 分支），A4 永远不出现。
>
> 完整设计理由见 [docs/container-startup.md](docs/container-startup.md)。

## 🔧 开发环境

### 本地搭建

```bash
# 前端
cd frontend && bun install && bun run dev    # :5173，代理 /api → :8090

# 后端
go mod download
go build -o bin/cups-web ./cmd/server && ./bin/cups-web    # :8080
```

### Makefile

```bash
make all            # 前端 dist + Go 二进制（必须先前端再后端）
make frontend       # 仅前端
make build          # 仅后端（禁止裸 go build ./cmd/server）
make docker-build   # AIO 镜像
```

### Vite 开发代理

`/api → http://localhost:8090`。本地调试：后端 `LISTEN_ADDR=:8090 go run ./cmd/server`，前端 `bun run dev`。

### 构建产物分包

`vue-vendor`（vue/router）、`ui-vendor`（nuxt-ui/reka-ui/vueuse）、`pdf-vendor`（pdfjs-dist）。

## 🚢 部署

### docker-compose

单服务 `cups`（AIO），`image: hanxi/cups-web:latest`，端口 `631:631` + `1180:8080`。

| 配置 | 为什么 |
| --- | --- |
| `user: root` | cupsd / lpadmin / dpkg / 写系统路径 |
| `security_opt: [apparmor:unconfined]` | PVE LXC AppArmor DENIED（issue #91） |
| `./.etc:/etc/cups`、`./.data:/data`、`./.uploads:/uploads` | 持久化 |
| **`./.drivers:/opt/cups-drivers/data`** | **驱动快照持久化**（删 = 重启丢驱动） |
| `/dev/bus/usb:/dev/bus/usb` + `device_cgroup_rules` | USB 热插拔（issue #81） |
| `/run/udev:/run/udev:ro` | libusb 设备属性（可选） |
| `/run/dbus/system_bus_socket:/run/dbus/system_bus_socket` | 共享宿主机 D-Bus system bus socket，让 CUPS 通过宿主机 avahi 广播 AirPrint（issue #94） |

### Docker 构建

五阶段：`frontend-build`（node:20-slim）→ `java-builder`（BUILDPLATFORM 锁 amd64）→ `builder`（golang:1.26）→ `cups-builder`（源码编译 CUPS）→ `runtime`（trixie-slim）。覆盖 `linux/amd64` + `arm64` + `arm/v7`。

> 🚨 `cups-builder` 的 `ca-certificates` 请勿删除（wget TLS 校验，删了 CI 直接崩）。
>
> ⚠️ **`/etc/cups/*` 来自 apt 的 `cups-daemon`（trixie 2.4.10），不是源码编译那份。** `cups-builder` 打的 `cups-compiled.tar` 只含 `/usr` 路径，整个 `/etc` 都不在里面。所以：读 `cupsd.conf` 的 Location/Policy 出厂内容要按 **Debian 版**理解；而 `/usr/lib/cups/**`（filter、backend、`daemon/cups-driverd`）是**源码编译的 2.4.19**。这也是为什么绝不能让 apt 装 `cups-core-drivers` —— 它会用 Debian 版覆盖 overlay 解包的那批文件。
>
> ⚠️ `cupsd` **不会自己创建** `/etc/cups/ssl`（源码里那处 `cupsdCheckPermissions` 的 `create_dir` 传的是 0，`lstat` 失败时既不 mkdir 也不报错），缺了它要到第一次 ipps 握手才炸 `Unable to create server credentials`，而 AirPrint 客户端优先挑 `_ipps._tcp`。以前它之所以存在纯粹是因为 Debian 的 `cups-daemon` 把它作为 package-owned 空目录发布 —— 那是别人的实现细节，现在 Dockerfile 与 entrypoint 各显式建一次。
>
> 五阶段设计理由、三架构镜像选型史、HOME/LibreOffice profile 见 [docs/docker-build.md](docs/docker-build.md)。

### CI/CD

- **`build-release.yml`**：7 平台交叉编译 + tag 自动 Release。Go 版本与 `go.mod` 一致（`1.26`）。
- **`docker-publish.yml`**：`master` / `v*` tag → 三架构镜像。开头有 `Free disk space` 步骤。

### 版本管理

`./bump-version.sh patch|minor|major`

## 🎯 常见开发任务 / 调试 / 代码风格

> 新增 API、修改 DB、新增前端页面、新增文件类型、新增驱动的步骤模板，以及调试命令、Go/Vue 风格、Git 提交约定，见 [docs/conventions.md](docs/conventions.md)。
>
> 🚫 **commit message 禁止 `Co-Authored-By` 及任何 AI 署名行**，中文撰写。

**维护者**：涵曦（<im.hanxi@gmail.com>）
