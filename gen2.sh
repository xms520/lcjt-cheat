python3 - <<'PY'
p='LCJTTweak.x'
s=open(p,encoding='utf8').read()
# 1) 探针增强: 除 LuaJIT GCstr 校验外, 增加"可读串密度"兜底统计
s=s.replace('''static void LCJTProbeAsync(void) {''','''// 兜底: 统计可读串密度(不依赖 LuaJIT 内部布局), 便于确认是否已加载脚本
static void LCJTDumpAllASCII(FILE *out) {
    const size_t kChunk = 1 << 22;
    uint8_t *buf = malloc(kChunk + 8);
    if (!buf) return;
    vm_address_t addr = 0; vm_size_t vsz = 0; uint32_t depth = 0;
    uint64_t total = 0;
    while (total < (uint64_t)384 * 1024 * 1024) {
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        vm_size_t isz = sizeof(info);
        if (vm_region_recurse_64(mach_task_self(), &addr, &vsz, &depth,
                                 (vm_region_info_t)&info, &cnt) != KERN_SUCCESS || vsz == 0) break;
        if ((info.protection & 3) == 3) {
            size_t off = 0;
            while (off < vsz && total < (uint64_t)384 * 1024 * 1024) {
                size_t want = vsz - off; if (want > kChunk) want = kChunk;
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), addr + off, (vm_size_t)want,
                                      (vm_address_t)buf, &got) == KERN_SUCCESS && got > 8) {
                    size_t i = 0;
                    while (i + 6 < got) {
                        if (buf[i] >= 0x20 && buf[i] < 0x7f) {
                            size_t j = i;
                            while (j < got && buf[j] >= 0x20 && buf[j] < 0x7f && (j - i) < 48) j++;
                            if (j - i >= 6 && (j == got || buf[j] == 0)) {
                                if (out) { fwrite(buf + i, 1, j - i, out); fputc('\\n', out); }
                            }
                            i = j;
                        } else i++;
                    }
                    total += got; off += got;
                } else off += want;
            }
        }
        addr += vsz;
        if (!addr) break;
    }
    free(buf);
}

static void LCJTProbeAsync(void) {''')
# 2) 在 LCJTProbeLua 末尾追加全量 ASCII dump
s=s.replace('''    g_note = [NSString stringWithFormat:@"探针完成 串%llu 块%llu", nStr, nLJ];
}''','''    g_note = [NSString stringWithFormat:@"探针完成 串%llu 块%llu", nStr, nLJ];
    // 兜底: 全量可读串
    NSString *ap = [LCJTDocPath() stringByAppendingPathComponent:@"lcjt_ascii_all.txt"];
    FILE *a = fopen(ap.UTF8String, "w");
    if (a) { LCJTDumpAllASCII(a); fclose(a); }
    LCJTLog(@"兜底 ASCII dump -> %@", ap);
}''')
open(p,'w',encoding='utf8').write(s)
print('patched')
PY
wc -l LCJTTweak.x
