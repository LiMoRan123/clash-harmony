import { SubscriptionInfo } from '../models/Profile';

// Subscription-Userinfo reports account counters in bytes and expiry in Unix
// seconds. Unknown fields stay unknown; the YAML file size is unrelated.
export class SubscriptionInfoService {
  static fromHeaders(headers: Object | undefined): SubscriptionInfo | undefined {
    if (!headers) { return undefined }
    if (typeof headers === 'string') {
      try { return SubscriptionInfoService.fromHeaders(JSON.parse(headers) as Object) }
      catch (err) { return undefined }
    }
    if (typeof headers !== 'object' || Array.isArray(headers)) { return undefined }
    const fields = headers as Record<string, Object>;
    for (const key of Object.keys(fields)) {
      if (key.trim().toLowerCase() !== 'subscription-userinfo') { continue }
      const value: Object = fields[key];
      if (typeof value === 'string') { return SubscriptionInfoService.parse(value) }
      if (Array.isArray(value)) {
        const parts: string[] = [];
        for (const part of value as Object[]) {
          if (typeof part === 'string') { parts.push(part) }
        }
        return SubscriptionInfoService.parse(parts.join(';'));
      }
    }
    return undefined;
  }

  static parse(text: string): SubscriptionInfo | undefined {
    if (text.length > 8192) { return undefined }
    const info: SubscriptionInfo = {};
    for (const field of text.split(/[;,]/)) {
      const separator: number = field.indexOf('=');
      if (separator < 0) { continue }
      const key: string = field.substring(0, separator).trim().toLowerCase();
      if (!['upload', 'download', 'total', 'expire'].includes(key)) { continue }
      const raw: string = field.substring(separator + 1).trim();
      if (!/^\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(raw)) { continue }
      const value: number = Number(raw);
      if (!Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) { continue }
      const count: number = Math.trunc(value);
      if (key === 'upload') { info.upload = count }
      if (key === 'download') { info.download = count }
      if (key === 'total') { info.total = count }
      if (key === 'expire' && count <= 8640000000000) { info.expire = count }
    }
    return SubscriptionInfoService.normalize(info);
  }

  static normalize(value: SubscriptionInfo | undefined): SubscriptionInfo | undefined {
    if (!value || typeof value !== 'object' || Array.isArray(value)) { return undefined }
    const info: SubscriptionInfo = {};
    if (SubscriptionInfoService.validCount(value.upload)) { info.upload = value.upload }
    if (SubscriptionInfoService.validCount(value.download)) { info.download = value.download }
    if (SubscriptionInfoService.validCount(value.total)) { info.total = value.total }
    if (SubscriptionInfoService.validCount(value.expire) && value.expire! <= 8640000000000) {
      info.expire = value.expire;
    }
    return Object.keys(info).length > 0 ? info : undefined;
  }

  private static validCount(value: number | undefined): boolean {
    return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
  }

  static checkedAt(value: number | undefined): number | undefined {
    return SubscriptionInfoService.validCount(value) && value! > 0 && value! <= 8640000000000000 ? value : undefined;
  }

  static usedBytes(info: SubscriptionInfo): number | undefined {
    if (info.upload === undefined || info.download === undefined) { return undefined }
    const used: number = info.upload + info.download;
    return Number.isSafeInteger(used) && used >= 0 ? used : undefined;
  }

  static usagePercent(info: SubscriptionInfo): number | undefined {
    const used: number | undefined = SubscriptionInfoService.usedBytes(info);
    if (used === undefined || info.total === undefined || info.total <= 0) { return undefined }
    return Math.min(100, used / info.total * 100);
  }

  static exhausted(info: SubscriptionInfo): boolean {
    const used: number | undefined = SubscriptionInfoService.usedBytes(info);
    return used !== undefined && info.total !== undefined && info.total > 0 && used >= info.total;
  }

  static usageText(info: SubscriptionInfo): string {
    const used: number | undefined = SubscriptionInfoService.usedBytes(info);
    const total: number | undefined = info.total;
    if (used !== undefined) {
      const text: string = '已用 ' + SubscriptionInfoService.formatBytes(used);
      if (total !== undefined && total > 0) {
        return text + ' / ' + SubscriptionInfoService.formatBytes(total) + ' · ' +
          (used >= total ? '额度已用尽' : '剩余 ' + SubscriptionInfoService.formatBytes(total - used));
      }
      return text + ' · 总额度未提供';
    }
    const parts: string[] = [];
    if (info.upload !== undefined) { parts.push('上传 ' + SubscriptionInfoService.formatBytes(info.upload)) }
    if (info.download !== undefined) { parts.push('下载 ' + SubscriptionInfoService.formatBytes(info.download)) }
    if (total !== undefined && total > 0) { parts.push('总量 ' + SubscriptionInfoService.formatBytes(total)) }
    return parts.length > 0 ? parts.join(' · ') : '流量信息未提供';
  }

  static expired(info: SubscriptionInfo, now: number = Date.now()): boolean {
    return info.expire !== undefined && info.expire > 0 && info.expire * 1000 <= now;
  }

  static expiryText(info: SubscriptionInfo, now: number = Date.now()): string {
    if (info.expire === undefined || info.expire <= 0) { return '到期时间未提供' }
    const date: Date = new Date(info.expire * 1000);
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    return date.getFullYear() + '-' + month + '-' + day +
      (SubscriptionInfoService.expired(info, now) ? ' 已到期' : ' 到期');
  }

  static formatBytes(bytes: number): string {
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let value: number = bytes;
    let unit: number = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
    return (unit === 0 ? value.toString() : value.toFixed(1)) + ' ' + units[unit];
  }
}
