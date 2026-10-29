import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ClashProfile, ProfileState, SubscriptionInfo } from '../models/Profile';
import { ProfileStore } from './ProfileStore';
import { AppPreferences, AppPreferencesService } from './AppPreferencesService';
import { GenericSubscriptionConverterService } from './GenericSubscriptionConverterService';
import { SubscriptionInfoService } from './SubscriptionInfoService';

interface PortableProfile {
  name: string;
  type: string;
  source: string;
  text: string;
  nodeCount: number;
  traffic: string;
  subscriptionInfo?: SubscriptionInfo;
  subscriptionInfoCheckedAt?: number;
}

interface PortableBackup {
  format: string;
  version: number;
  createdAt: number;
  currentIndex: number;
  profiles: PortableProfile[];
  preferences: AppPreferences;
}

export class AppBackupService {
  static async create(context: common.Context): Promise<string> {
    const state: ProfileState = await ProfileStore.load(context);
    const profiles: PortableProfile[] = [];
    for (let index = 0; index < state.items.length; index++) {
      const item: ClashProfile = state.items[index];
      profiles.push({
        name: item.name, type: item.type, source: item.type === 'remote' ? item.source : '',
        text: item.filePath.length > 0 ? await fileIo.readText(item.filePath) : '',
        nodeCount: item.nodeCount, traffic: item.traffic,
        subscriptionInfo: item.type === 'remote' ? SubscriptionInfoService.normalize(item.subscriptionInfo) : undefined,
        subscriptionInfoCheckedAt: item.type === 'remote' ? SubscriptionInfoService.checkedAt(item.subscriptionInfoCheckedAt) : undefined
      });
    }
    const bundle: PortableBackup = {
      format: 'clash-harmony', version: 1, createdAt: Date.now(),
      currentIndex: state.items.findIndex((item: ClashProfile) => item.uid === state.currentUid),
      profiles: profiles, preferences: await AppPreferencesService.load(context)
    };
    return JSON.stringify(bundle, null, 2);
  }

  static async restore(context: common.Context, text: string): Promise<ProfileState> {
    const bundle: PortableBackup = JSON.parse(text) as PortableBackup;
    if (!bundle || bundle.format !== 'clash-harmony' || bundle.version !== 1 || !Array.isArray(bundle.profiles)) {
      throw new Error('这不是受支持的喵连 / Clash Harmony 备份');
    }
    // Validate every profile before replacing the user's current profile list.
    for (let index = 0; index < bundle.profiles.length; index++) {
      const item: PortableProfile = bundle.profiles[index];
      if (!item || typeof item.name !== 'string' || typeof item.text !== 'string' ||
        typeof item.source !== 'string' || typeof item.traffic !== 'string' ||
        typeof item.nodeCount !== 'number' || !Number.isFinite(item.nodeCount) ||
        (item.type !== 'remote' && item.type !== 'local')) {
        throw new Error('备份中的配置数据不完整');
      }
      if (item.text.length === 0 && (item.type !== 'remote' || !/^https?:\/\//.test(item.source))) {
        throw new Error('备份中的配置内容为空');
      }
      if (item.text.length > 0 && !GenericSubscriptionConverterService.normalizeToClashYaml(item.text).ok) {
        throw new Error('备份包含无法识别的配置：' + item.name);
      }
    }
    const restoredPreferences: AppPreferences | undefined = bundle.preferences
      ? AppPreferencesService.normalize(bundle.preferences) : undefined;
    const directory: string = context.filesDir + '/profiles';
    try { await fileIo.mkdir(directory, true); } catch (err) {}
    const items: ClashProfile[] = [];
    const now: number = Date.now();
    for (let index = 0; index < bundle.profiles.length; index++) {
      const item: PortableProfile = bundle.profiles[index];
      const uid: string = 'restored_' + now + '_' + index;
      const path: string = item.text.length > 0 ? directory + '/' + uid + '.yaml' : '';
      if (path.length > 0) {
        const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try { await fileIo.write(file.fd, item.text); } finally { fileIo.closeSync(file); }
      }
      items.push({
        uid: uid, type: item.type === 'remote' ? 'remote' : 'local', name: item.name,
        source: item.type === 'remote' ? item.source : path, filePath: path, updatedAt: now,
        nodeCount: item.nodeCount > 0 ? item.nodeCount : 0, traffic: item.traffic || '未知',
        subscriptionInfo: item.type === 'remote' ? SubscriptionInfoService.normalize(item.subscriptionInfo) : undefined,
        subscriptionInfoCheckedAt: item.type === 'remote' ? SubscriptionInfoService.checkedAt(item.subscriptionInfoCheckedAt) : undefined
      });
    }
    const selected: number = Number.isInteger(bundle.currentIndex) &&
      bundle.currentIndex >= 0 && bundle.currentIndex < items.length ? bundle.currentIndex : 0;
    const state: ProfileState = { currentUid: items.length > 0 ? items[selected].uid : '', items: items };
    if (!await ProfileStore.save(context, state)) {
      throw new Error('恢复配置保存失败');
    }
    if (restoredPreferences) {
      await AppPreferencesService.save(context, restoredPreferences);
    }
    return state;
  }
}
