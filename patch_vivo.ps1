$ErrorActionPreference = "Stop"

$bakPath = "D:\program file\vivo office\pcsuite\resources\app.asar.bak"
$outPath = "D:\program file\vivo office\pcsuite\resources\app.asar"
$tmpPath = "D:\program file\vivo office\pcsuite\resources\app.asar.tmp"

Add-Type -AssemblyName System.Web.Extensions
Add-Type -ReferencedAssemblies "System.Web.Extensions" -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

public class AsarTool {
    public static Dictionary<string, object> ReadHeader(string asarPath, out long dataOffset) {
        using (var fs = File.OpenRead(asarPath))
        using (var br = new BinaryReader(fs)) {
            br.ReadUInt32(); // 4
            uint hdrPickle = br.ReadUInt32();
            br.ReadUInt32(); // json + pad
            uint jsonLen = br.ReadUInt32();
            dataOffset = 8 + (long)hdrPickle;
            byte[] jsonBytes = br.ReadBytes((int)jsonLen);
            string json = Encoding.UTF8.GetString(jsonBytes);
            var ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 200 };
            return ser.Deserialize<Dictionary<string, object>>(json);
        }
    }

    public static byte[] ReadFileBytes(string asarPath, long dataOffset, Dictionary<string, object> root, string relPath) {
        var cur = root;
        var parts = relPath.TrimStart('/').Split('/');
        for (int i = 0; i < parts.Length; i++) {
            var files = (Dictionary<string, object>)cur["files"];
            cur = (Dictionary<string, object>)files[parts[i]];
        }
        long offset = long.Parse(cur["offset"].ToString()) + dataOffset;
        int size = Convert.ToInt32(cur["size"]);
        using (var fs = File.OpenRead(asarPath)) {
            fs.Seek(offset, SeekOrigin.Begin);
            byte[] buf = new byte[size];
            int read = 0;
            while (read < size) {
                int r = fs.Read(buf, read, size - read);
                if (r <= 0) break;
                read += r;
            }
            return buf;
        }
    }

    private static Dictionary<string, object> ComputeIntegrity(byte[] data) {
        const int blockSize = 4194304;
        var blocks = new List<string>();
        using (var sha = SHA256.Create()) {
            string fullHash = BitConverter.ToString(sha.ComputeHash(data)).Replace("-", "").ToLowerInvariant();
            if (data.Length == 0) {
                blocks.Add(fullHash);
            } else {
                for (int off = 0; off < data.Length; off += blockSize) {
                    int len = Math.Min(blockSize, data.Length - off);
                    byte[] bh = sha.ComputeHash(data, off, len);
                    blocks.Add(BitConverter.ToString(bh).Replace("-", "").ToLowerInvariant());
                }
            }
            return new Dictionary<string, object> {
                { "algorithm", "SHA256" },
                { "hash", fullHash },
                { "blockSize", blockSize },
                { "blocks", blocks.ToArray() }
            };
        }
    }

    private class CopyPlan {
        public bool IsPatched;
        public byte[] PatchedBytes;
        public long SrcOffset;
        public long Size;
    }

    public static void Repack(string srcAsar, string dstAsar, Dictionary<string, byte[]> patchedMap) {
        long srcDataOffset;
        var root = ReadHeader(srcAsar, out srcDataOffset);
        var plans = new List<CopyPlan>();
        long nextOffset = 0;

        Action<Dictionary<string, object>, string> walk = null;
        walk = (node, path) => {
            var files = (Dictionary<string, object>)node["files"];
            foreach (var kv in files) {
                string full = path + "/" + kv.Key;
                var entry = (Dictionary<string, object>)kv.Value;
                if (entry.ContainsKey("files")) {
                    walk(entry, full);
                } else if (entry.ContainsKey("unpacked") && Convert.ToBoolean(entry["unpacked"])) {
                    // keep untouched
                } else {
                    long oldSize = Convert.ToInt64(entry["size"]);
                    long oldOff = long.Parse(entry["offset"].ToString());
                    if (patchedMap.ContainsKey(full)) {
                        byte[] nb = patchedMap[full];
                        entry["size"] = nb.Length;
                        entry["offset"] = nextOffset.ToString();
                        entry["integrity"] = ComputeIntegrity(nb);
                        plans.Add(new CopyPlan { IsPatched = true, PatchedBytes = nb, Size = nb.Length });
                        nextOffset += nb.Length;
                    } else {
                        entry["offset"] = nextOffset.ToString();
                        plans.Add(new CopyPlan { IsPatched = false, SrcOffset = oldOff + srcDataOffset, Size = oldSize });
                        nextOffset += oldSize;
                    }
                }
            }
        };
        walk(root, "");

        var ser = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 200 };
        string newJson = ser.Serialize(root);
        byte[] newJsonBytes = Encoding.UTF8.GetBytes(newJson);
        int jLen = newJsonBytes.Length;
        int pad = (4 - (jLen % 4)) % 4;
        uint hdrPayloadSize = (uint)(4 + 4 + jLen + pad);

        using (var fsIn = File.OpenRead(srcAsar))
        using (var fsOut = File.Create(dstAsar))
        using (var bw = new BinaryWriter(fsOut)) {
            bw.Write((uint)4);
            bw.Write(hdrPayloadSize);
            bw.Write((uint)(4 + jLen + pad));
            bw.Write((uint)jLen);
            bw.Write(newJsonBytes);
            for (int i = 0; i < pad; i++) bw.Write((byte)0);

            byte[] buf = new byte[1048576];
            foreach (var p in plans) {
                if (p.IsPatched) {
                    bw.Write(p.PatchedBytes);
                } else {
                    fsIn.Seek(p.SrcOffset, SeekOrigin.Begin);
                    long rem = p.Size;
                    while (rem > 0) {
                        int toRead = (int)Math.Min(buf.Length, rem);
                        int r = fsIn.Read(buf, 0, toRead);
                        if (r <= 0) throw new EndOfStreamException("Unexpected EOF");
                        bw.Write(buf, 0, r);
                        rem -= r;
                    }
                }
            }
        }
    }
}
"@

$dataOffset = [int64]0
$root = [AsarTool]::ReadHeader($bakPath, [ref]$dataOffset)

function Read-Text([string]$rel) {
  $b = [AsarTool]::ReadFileBytes($bakPath, $dataOffset, $root, $rel)
  return [System.Text.Encoding]::UTF8.GetString($b)
}

function Rep([string]$s, [string]$old, [string]$new, [string]$tag) {
  if ($s.IndexOf($old) -lt 0) { Write-Warning "MISS [$tag]" ; return $s }
  return $s.Replace($old, $new)
}

$patched = New-Object 'System.Collections.Generic.Dictionary[string,byte[]]'

# 1. main.js
$m = Read-Text "/dist/electron/main.js"
$m = Rep $m 'o.default.getItem("currentLanguage")||"en_US"' 'o.default.getItem("currentLanguage")||"vi_VN"' "main.getLocalesJson"
$m = Rep $m '(null!==(e=o.default.getItem("isExport"))&&void 0!==e&&e)!==g&&(o.default.removeItem("moduleSort"),o.default.setItem("isExport",g),g||(o.default.setItem("currentLanguage","zh_CN"),o.default.setItem("vLang","vzh_rCN"),o.default.setItem("isRtl",!1)))' '(null!==(e=o.default.getItem("isExport"))&&void 0!==e&&e)!==g&&(o.default.removeItem("moduleSort"),o.default.setItem("isExport",g)),g||(o.default.setItem("currentLanguage","vi_VN"),o.default.setItem("vLang","vvi"),o.default.setItem("isRtl",!1))' "main.handleExEnv"
$m = Rep $m 'this._isRtl=!1,this._currentLanguage="zh_CN"' 'this._isRtl=!1,this._currentLanguage="vi_VN"' "main.RtlManager"
$m = Rep $m 'n.includes(t)||n.includes(t.split("_")[0])||(t="en_US")' 'n.includes(t)||n.includes(t.split("_")[0])||(t="vi_VN")' "main.initFallback"
$m = Rep $m 'this._currentLanguage=(null==n?void 0:n.region)||"en_US"' 'this._currentLanguage=(null==n?void 0:n.region)||"vi_VN"' "main.nativeFallback"
$m = Rep $m '"undefined"!=typeof __buildConfig__&&__buildConfig__.IS_EXPORT?g.getLocalesJson("framework"):{}' 'g.getLocalesJson("framework")' "main.toastLocale"
$m = Rep $m '"undefined"!=typeof __buildConfig__&&__buildConfig__.IS_EXPORT?d.getLocalesJson("framework"):{}' 'd.getLocalesJson("framework")' "main.trayLocale"
$m = Rep $m '"undefined"!=typeof __buildConfig__&&__buildConfig__.IS_EXPORT?a.getLocalesJson("framework"):null' 'a.getLocalesJson("framework")' "main.menuLocale"
$m = Rep $m ':"vivo办公套件"' ':"Bộ công cụ vivo Office"' "main.appName"
$patched["/dist/electron/main.js"] = [System.Text.Encoding]::UTF8.GetBytes($m)

# 2. renderer.js
$r = Read-Text "/dist/electron/renderer.js"
$r = Rep $r 'function o(){if(!n)return"zh_CN";' 'function o(){if(!n)return"vi_VN";' "rend.getDefault"
$r = Rep $r 'const c=n?o():"zh_CN",d=new b.default({locale:c,fallbackLocale:n?"en_US":"zh_CN",messages:{}})' 'const c=n?o():"vi_VN",d=new b.default({locale:c,fallbackLocale:"vi_VN",messages:{}})' "rend.vueI18n"
$r = Rep $r '(null!==(l=b.default.getItem("isExport"))&&void 0!==l&&l)!==f&&(b.default.removeItem("moduleSort"),b.default.setItem("isExport",f),f||(b.default.setItem("currentLanguage","zh_CN"),b.default.setItem("vLang","vzh_rCN"),b.default.setItem("isRtl",!1)))' '(null!==(l=b.default.getItem("isExport"))&&void 0!==l&&l)!==f&&(b.default.removeItem("moduleSort"),b.default.setItem("isExport",f)),f||(b.default.setItem("currentLanguage","vi_VN"),b.default.setItem("vLang","vvi"),b.default.setItem("isRtl",!1))' "rend.handleExEnv"
$r = Rep $r 'this._isRtl=!1,this._currentLanguage="zh_CN"' 'this._isRtl=!1,this._currentLanguage="vi_VN"' "rend.RtlManager"
$r = Rep $r 'lang:null!==(b=s.default.getItem("currentLanguage"))&&void 0!==b?b:"zh_CN"' 'lang:null!==(b=s.default.getItem("currentLanguage"))&&void 0!==b&&"zh_CN"!==b?b:"vi_VN"' "rend.vuexLang"
$r = Rep $r 'let l=t.default.locale||"zh_CN"' 'let l=t.default.locale||"vi_VN"' "rend.formatjs1"
$r = Rep $r 'underscoreToFormatCodeMap[t.default.locale||"zh_CN"]' 'underscoreToFormatCodeMap[t.default.locale||"vi_VN"]' "rend.formatjs2"
$r = Rep $r 'get isCn(){return!("undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT&&this.lang)||["zh_CN"].includes(this.lang)}' 'get isCn(){return["zh_CN"].includes(this.lang)}' "rend.isCn"
$r = Rep $r '[{name:"同步设置",key:"account",pcNumber:1,webNumber:1},{name:"同步设置",key:"sync",pcNumber:2},{name:"framework.setDigConfigMenuName2",key:"common",pcNumber:2},{name:"framework.setDigConfigMenuName3",key:"featureSet",open:!0,children:[{name:"framework.setDigConfigMenuName4",key:"pcScreen",hidden:u,pcNumber:"3_5"},{name:v?"note.noteAbroadTitle":"笔记",key:"note",pcNumber:"3_1",webNumber:"3_1"},{name:"日历",key:"calendar",pcNumber:"3_2",webNumber:"3_2"},{name:"录音机",key:"recorder",pcNumber:"3_7",webNumber:"3_7"},{name:"蓝心小V",key:"vTalk",hidden:u,pcNumber:"3_6"}]}' '[{name:"Cài đặt đồng bộ",key:"account",pcNumber:1,webNumber:1},{name:"Cài đặt đồng bộ",key:"sync",pcNumber:2},{name:"framework.setDigConfigMenuName2",key:"common",pcNumber:2},{name:"framework.setDigConfigMenuName3",key:"featureSet",open:!0,children:[{name:"framework.setDigConfigMenuName4",key:"pcScreen",hidden:u,pcNumber:"3_5"},{name:"note.noteAbroadTitle",key:"note",pcNumber:"3_1",webNumber:"3_1"},{name:"Lịch",key:"calendar",pcNumber:"3_2",webNumber:"3_2"},{name:"Ghi âm",key:"recorder",pcNumber:"3_7",webNumber:"3_7"},{name:"Trợ lý AI",key:"vTalk",hidden:u,pcNumber:"3_6"}]}' "rend.menuList"
$r = Rep $r '[{name:"同步设置",key:"account"},{name:"同步设置",key:"sync",children:[{name:"相册",key:"space-optimization"}]},{name:"framework.setDigConfigMenuName2",key:"common",children:[{name:"framework.setDigConfigRouteIName1",key:"home-privacy"}]},{name:"framework.setDigConfigMenuName3",key:"featureSet",path:"/",children:[{name:v?"note.noteAbroadTitle":"笔记"' '[{name:"Cài đặt đồng bộ",key:"account"},{name:"Cài đặt đồng bộ",key:"sync",children:[{name:"Album",key:"space-optimization"}]},{name:"framework.setDigConfigMenuName2",key:"common",children:[{name:"framework.setDigConfigRouteIName1",key:"home-privacy"}]},{name:"framework.setDigConfigMenuName3",key:"featureSet",path:"/",children:[{name:"note.noteAbroadTitle"' "rend.routeSetting"
$r = Rep $r 'case"note":return"undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT?""+this.$t("note.noteAbroadTitle"):"原子笔记";case"calendar":return"日历";case"album":return"相册";case"vivoControl":return""+this.$t("framework.leftSidebarTitle4");case"cloudService":return"云服务";case"record":return"录音机";' 'case"note":return""+this.$t("note.noteAbroadTitle");case"calendar":return"Lịch";case"album":return"Album";case"vivoControl":return""+this.$t("framework.leftSidebarTitle4");case"cloudService":return"Dịch vụ đám mây";case"record":return"Ghi âm";' "rend.getTips"
$r = Rep $r 'this.isExport?this.$t("note.autoSyncNotes"):"原子笔记"' 'this.$t("note.autoSyncNotes")' "rend.syncSettingList"
$r = Rep $r ':"vivo办公套件"' ':"Bộ công cụ vivo Office"' "rend.appName"
$patched["/dist/electron/renderer.js"] = [System.Text.Encoding]::UTF8.GetBytes($r)

# 3. child-window.js & module-share-preview.js
foreach ($cwFile in @("/dist/electron/child-window.js", "/dist/electron/module-share-preview.js")) {
  $t = Read-Text $cwFile
  $t = Rep $t 'if(!l)return"zh_CN";' 'if(!l)return"vi_VN";' "$cwFile.getDefault"
  $t = $t.Replace('const u=l?c():"zh_CN",E=new a.default({locale:u,fallbackLocale:l?"en_US":"zh_CN",messages:{}})', 'const u=l?c():"vi_VN",E=new a.default({locale:u,fallbackLocale:"vi_VN",messages:{}})')
  $t = $t.Replace('const u=l?c():"zh_CN",E=new s.default({locale:u,fallbackLocale:l?"en_US":"zh_CN",messages:{}})', 'const u=l?c():"vi_VN",E=new s.default({locale:u,fallbackLocale:"vi_VN",messages:{}})')
  $t = $t.Replace('("currentLanguage","zh_CN")', '("currentLanguage","vi_VN")')
  $t = $t.Replace('("vLang","vzh_rCN")', '("vLang","vvi")')
  $t = $t.Replace('this._isRtl=!1,this._currentLanguage="zh_CN"', 'this._isRtl=!1,this._currentLanguage="vi_VN"')
  $t = $t.Replace('||"zh_CN"', '||"vi_VN"').Replace(':"zh_CN"', ':"vi_VN"')
  $patched[$cwFile] = [System.Text.Encoding]::UTF8.GetBytes($t)
}

# 4. note-toolbar.js
$nt = Read-Text "/dist/electron/note-toolbar.js"
$nt = $nt.Replace('!("undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT&&this.lang)||["zh_CN"].includes(this.lang)', '["zh_CN"].includes(this.lang)')
$nt = $nt.Replace('!(this.isExport&&this.$i18n&&this.$i18n.locale)||["zh_CN"].includes(this.$i18n.locale)', '["zh_CN"].includes(this.$i18n.locale)')
$nt = $nt.Replace('!(this.isExport&&I.default.state.common&&I.default.state.common.lang)||["zh_CN"].includes(I.default.state.common.lang)', '["zh_CN"].includes(I.default.state.common.lang)')
$patched["/dist/electron/note-toolbar.js"] = [System.Text.Encoding]::UTF8.GetBytes($nt)

# 5. app-components.js
$ac = Read-Text "/dist/electron/app-components.js"
$ac = $ac.Replace('!("undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT&&T.a.state.common&&T.a.state.common.lang)||["zh_CN"].includes(T.a.state.common.lang)', '["zh_CN"].includes(T.a.state.common.lang)')
$ac = $ac.Replace('"undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT?this.$t("note.noteAbroadTitle"):"原子笔记"', 'this.$t("note.noteAbroadTitle")')
$patched["/dist/electron/app-components.js"] = [System.Text.Encoding]::UTF8.GetBytes($ac)

# 6. app-modules-note.js & 126.js
$amn = Read-Text "/dist/electron/app-modules-note.js"
$amn = $amn.Replace('!(this.isExport&&this.$i18n&&this.$i18n.locale)||["zh_CN"].includes(this.$i18n.locale)', '["zh_CN"].includes(this.$i18n.locale)')
$amn = Rep $amn 'e.isExport||(this.editorConfig.language="zh_CN_in",e.fire("VnoteSetLang",{code:"zh_CN_in"}))' '(this.editorConfig.language="vi_VN",e.fire("VnoteSetLang",{code:q.getEditorLanguage("vi_VN")}))' "amn.editorLang"
$patched["/dist/electron/app-modules-note.js"] = [System.Text.Encoding]::UTF8.GetBytes($amn)

$f126 = Read-Text "/dist/electron/126.js"
$f126 = Rep $f126 't.isExport||(this.editorConfig.language="zh_CN_in",t.fire("VnoteSetLang",{code:"zh_CN_in"}))' '(this.editorConfig.language="vi_VN",t.fire("VnoteSetLang",{code:J.getEditorLanguage("vi_VN")}))' "126.editorLang"
$patched["/dist/electron/126.js"] = [System.Text.Encoding]::UTF8.GetBytes($f126)

# 7. components-connection.js, 127.js, 128.js, 144.js
$cc = Read-Text "/dist/electron/components-connection.js"
$cc = $cc.Replace('!("undefined"==typeof window||!window.__buildConfig__||!window.__buildConfig__.IS_EXPORT)&&"zh_CN"!==this.lang', '"zh_CN"!==this.lang')
$cc = $cc.Replace('this.isExport&&"zh_CN"!==this.lang', '"zh_CN"!==this.lang')
$patched["/dist/electron/components-connection.js"] = [System.Text.Encoding]::UTF8.GetBytes($cc)

$f127 = Read-Text "/dist/electron/127.js"
$f127 = $f127.Replace('!("undefined"==typeof window||!window.__buildConfig__||!window.__buildConfig__.IS_EXPORT)&&"zh_CN"!==this.lang', '"zh_CN"!==this.lang')
$f127 = $f127.Replace(':"vivo办公套件"', ':"Bộ công cụ vivo Office"').Replace(':"vivo办公套件摄像头"', ':"Camera ảo vivo"')
$patched["/dist/electron/127.js"] = [System.Text.Encoding]::UTF8.GetBytes($f127)

$f128 = Read-Text "/dist/electron/128.js"
$f128 = $f128.Replace('!("undefined"==typeof window||!window.__buildConfig__||!window.__buildConfig__.IS_EXPORT)&&"zh_CN"!==this.lang', '"zh_CN"!==this.lang')
$f128 = $f128.Replace('default:"zh_CN"', 'default:"vi_VN"').Replace('e.lang||"zh_CN"', 'e.lang||"vi_VN"')
$f128 = $f128.Replace('"undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT?"note.noteAbroadTitle":"原子笔记"', '"note.noteAbroadTitle"')
$f128 = $f128.Replace('subTitle:"最近的笔记"', 'subTitle:"Ghi chú gần đây"')
$patched["/dist/electron/128.js"] = [System.Text.Encoding]::UTF8.GetBytes($f128)

$f144 = Read-Text "/dist/electron/144.js"
$f144 = $f144.Replace('!("undefined"==typeof window||!window.__buildConfig__||!window.__buildConfig__.IS_EXPORT)&&"zh_CN"!==this.localeLang', '"zh_CN"!==this.localeLang')
$patched["/dist/electron/144.js"] = [System.Text.Encoding]::UTF8.GetBytes($f144)

# 8. app-connection.js
$aconn = Read-Text "/dist/electron/app-connection.js"
$aconn = $aconn.Replace(':"vivo办公套件"', ':"Bộ công cụ vivo Office"')
$patched["/dist/electron/app-connection.js"] = [System.Text.Encoding]::UTF8.GetBytes($aconn)

# 9. 133.js, 134.js, 157.js, 163.js, 165.js, 181.js, webviewPreload.js
foreach ($fn in @("/dist/electron/133.js","/dist/electron/134.js","/dist/electron/163.js","/dist/electron/165.js","/dist/electron/webviewPreload.js")) {
  $t = Read-Text $fn
  $t = $t.Replace('e.lang||"zh_CN"', 'e.lang||"vi_VN"').Replace('this.lang||"zh_CN"', 'this.lang||"vi_VN"').Replace('language:"zh_CN"', 'language:"vi_VN"').Replace('lang:"zh_CN"', 'lang:"vi_VN"')
  $patched[$fn] = [System.Text.Encoding]::UTF8.GetBytes($t)
}

$f157 = Read-Text "/dist/electron/157.js"
$f157 = Rep $f157 'calendar:"日历",note:""+("undefined"!=typeof window&&window.__buildConfig__&&window.__buildConfig__.IS_EXPORT?this.$t("note.noteAbroadTitle"):"原子笔记"),album:"相册",record:"录音机"' 'calendar:"Lịch",note:""+this.$t("note.noteAbroadTitle"),album:"Album",record:"Ghi âm"' "157.moduleNameText"
$patched["/dist/electron/157.js"] = [System.Text.Encoding]::UTF8.GetBytes($f157)

$f181 = Read-Text "/dist/electron/181.js"
$f181 = Rep $f181 '!1' '!1' "noop"
$f181 = Rep $f181 '!("undefined"==typeof window||!window.__buildConfig__||!window.__buildConfig__.IS_EXPORT)' '!0' "181.noteAbroad"
$patched["/dist/electron/181.js"] = [System.Text.Encoding]::UTF8.GetBytes($f181)

# 10. HTML files
foreach ($hf in @("/dist/electron/index.html","/dist/electron/child-window.html","/dist/electron/module-share-preview.html")) {
  $t = Read-Text $hf
  $t = $t.Replace('<title>vivo办公套件</title>', '<title>Bộ công cụ vivo Office</title>').Replace('正在加载...', 'Đang tải...')
  $patched[$hf] = [System.Text.Encoding]::UTF8.GetBytes($t)
}

Write-Host "Repacking $($patched.Count) patched files into $tmpPath..."
[AsarTool]::Repack($bakPath, $tmpPath, $patched)

Write-Host "Stopping running pcsuite/vivocontrol processes..."
Get-Process | Where-Object { $_.ProcessName -match "^pcsuite$|^vivocontrol$" } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

Move-Item -LiteralPath $tmpPath -Destination $outPath -Force

# Update AppData config.ini and config.json
$iniPath = "$env:APPDATA\pcsuite\config.ini"
if (Test-Path $iniPath) {
  $ini = [System.IO.File]::ReadAllText($iniPath, [System.Text.Encoding]::UTF8)
  $ini = $ini -replace "LanguageTag=.*", "LanguageTag=vi_VN"
  $ini = $ini -replace "LanguageID=.*", "LanguageID=1066"
  [System.IO.File]::WriteAllText($iniPath, $ini, (New-Object System.Text.UTF8Encoding($false)))
}

$cfgPath = "$env:APPDATA\pcsuite\config.json"
if (Test-Path $cfgPath) {
  $cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $cfg | Add-Member -NotePropertyName "currentLanguage" -NotePropertyValue "vi_VN" -Force
  $cfg | Add-Member -NotePropertyName "vLang" -NotePropertyValue "vvi" -Force
  $cfg | Add-Member -NotePropertyName "appName" -NotePropertyValue "Bộ công cụ vivo Office" -Force
  $jsonOut = $cfg | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($cfgPath, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "VERIFYING repacked app.asar..."
$verOff = [int64]0
$verRoot = [AsarTool]::ReadHeader($outPath, [ref]$verOff)
Write-Host "SUCCESS! Size=$((Get-Item $outPath).Length), DataOffset=$verOff, TopKeys=$($verRoot['files'].Keys -join ',')"
