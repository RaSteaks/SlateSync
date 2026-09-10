// 从 MOV/MP4 文件中定位并读取 moov atom，供内嵌元数据解析使用。
// 设计约束：素材文件动辄数 GB（如 8K ProRes），绝不允许整读——只按 8 字节
// 步长读取顶级 atom 头，利用 size 字段跳过 mdat 等媒体数据，最后一次性读出
// moov（通常仅 1-4 MB，含封面图与采样表）。moov 可能在文件头（faststart）
// 或文件尾（DJI 默认），本读取器两种布局都支持。
import { open } from "node:fs/promises";

// 默认 moov 读取上限：覆盖数小时素材的采样表 + 封面图；超出视为异常文件。
export const DEFAULT_MAX_MOOV_BYTES = 64 * 1024 * 1024;

// 定位并返回完整的 moov atom（含 8 字节 size/type 头）。
// 返回 null 表示文件没有 moov 结构（损坏文件或非 QuickTime 容器）。
// 超出 maxBytes 抛错，避免把超大异常文件整个读入内存。
export async function readQuickTimeMoov(filePath, maxBytes = DEFAULT_MAX_MOOV_BYTES) {
  const handle = await open(filePath, "r");
  try {
    const fileStat = await handle.stat();
    // 头部缓冲同时容纳 32 位与 64 位（largesize）atom 头
    const header = Buffer.alloc(16);
    let offset = 0;
    while (offset + 8 <= fileStat.size) {
      const { bytesRead } = await handle.read(header, 0, 8, offset);
      if (bytesRead < 8) break;
      let size = header.readUInt32BE(0);
      const type = header.toString("latin1", 4, 8);
      let headerSize = 8;
      if (size === 1) {
        // 64 位扩展长度
        await handle.read(header, 0, 16, offset);
        size = Number(header.readBigUInt64BE(8));
        headerSize = 16;
      } else if (size === 0) {
        // 顶级 size=0 表示延伸到文件末尾
        size = fileStat.size - offset;
      }
      if (size < headerSize) break;

      if (type === "moov") {
        if (size > maxBytes) {
          // 错误信息不含路径：扫描器会把本模块的报错原样收进用户可见警告，
          // 素材名由调用方（slate-scanner）统一以 sourceName 前缀包装
          throw new Error(
            `的 moov 元数据约 ${Math.round(size / 1048576)} MB，超过 ${Math.round(maxBytes / 1048576)} MB 读取上限`,
          );
        }
        const moov = Buffer.alloc(size);
        await handle.read(moov, 0, size, offset);
        return moov;
      }
      offset += size;
    }
    return null;
  } finally {
    await handle.close();
  }
}
