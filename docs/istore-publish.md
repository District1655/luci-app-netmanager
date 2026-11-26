# 自动发版：Release → 构建 ipk/apk → 自动提 PR 到 iStore

## 它做了什么

`push main`（改 README 里的版本号）→ 原有 `Build Install Package` 打 tag、发 Release（tar.gz 安装包，body 从 `docs/CHANGELOG.md` 提取）
→ `Publish to iStore`（本流程）被 Release 触发，会：

1. 校验 `files/usr/sbin/netmanager` 里的 `PLUGIN_VERSION` 与发布版本一致，不一致直接失败（避免发出去的包版本对不上）
2. `tools/build_ipk.py` 打出 `luci-app-netmanager_<ver>-r<rel>_all.ipk`（opkg / 24.10 及更早）
3. `tools/build_apk.sh` 用官方 `openwrt-sdk-mini-25.12.2` 的 `apk mkpkg` 打出 `luci-app-netmanager-<ver>-r<rel>.apk`（25.12）
4. 两个包自动上传到对应的 Release 资产
5. `tools/publish_istore.sh` 向官方仓库提两个 PR：
   - `istoreos/istore-repo`，base `pending`，包放到 `bin/packages/all/nas_luci/` 与 `bin/apks/all/nas_luci/`
   - `istoreos/openwrt-app-meta`，base `main`，更新 `applications/app-meta-netmanager/`（版本号取自 `istore/app-meta/Makefile` 模板）

合并进 `pending` 后，官方 CI 会自动销旧包、重建索引并同步到 `repo.istoreos.com`，用户侧几分钟后即可在软件中心看到。

## 一次性配置

1. 建一个 PAT（Classic token，勾 `repo` 权限；或 Fine-grained 勾两个 fork 的 `Contents: Read and write` + `Pull requests: Read and write`）
2. 仓库 `Settings → Secrets and variables → Actions → New repository secret`
   - 名称：`ISTORE_TOKEN`
   - 值：上面那个 PAT
3. 没配 token 也能跑：只构建并挂到 Release，跳过提 PR（日志里会有提示）

## 日常发版

1. 改代码
2. 改两处版本号，保持一致：
   - `README.md` 头部的 `版本：vX.Y.Z`
   - `files/usr/sbin/netmanager` 里的 `PLUGIN_VERSION="X.Y.Z"`
3. push 到 `main`

流水线跑完，Release 里就有 tar.gz + ipk + apk，iStore 两个 PR 也已自动开好。

## 同版本重发

改了包内容但版本号不变时，手动跑 `Publish to iStore`，`release` 填 `2`、`3`…（apk 版本会变成 `X.Y.Z-r2`）。

## 只在本地出包

```bash
python3 tools/build_ipk.py --version 1.8.14 --release 1 --files files --out dist
VERSION=1.8.14 RELEASE=1 OUT=dist bash tools/build_apk.sh
```

## 常见问题

- **PR 打回**：官方只收 x86_64 / aarch64 架构；纯脚本包 `Architecture: all`（apk 是 `noarch`）没问题，带二进制要按架构分别出包
- **官方说包名冲突**：`luci-app-netmanager` 若与 OpenWrt 官方仓库重名，需改包名（如 `luci-app-nmgr`），同步改 `tools/build_*` 与 `istore/app-meta/Makefile`
- **apk 装不上**：本地验证用 `apk add --allow-untrusted xxx.apk`；进了官方 feed 后由签名索引兜底，用户侧不用加参数
