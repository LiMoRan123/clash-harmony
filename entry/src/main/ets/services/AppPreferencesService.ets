import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface AppPreferences {
  appearance: string;
  proxySort: string;
  proxyColumns: number;
  testTimeout: number;
  testUrl: string;
  ipv6: boolean;
  allowLan: boolean;
  dnsMode: string;
  logLevel: string;
}

export function defaultAppPreferences(): AppPreferences {
  return {
    appearance: 'system', proxySort: 'original', proxyColumns: 1,
    testTimeout: 4500, testUrl: 'https://cp.cloudflare.com/generate_204',
    ipv6: false, allowLan: false, dnsMode: 'redir-host', logLevel: 'info'
  };
}

export class AppPreferencesService {
  static normalize(value: AppPreferences): AppPreferences {
    const defaults: AppPreferences = defaultAppPreferences();
    return {
      appearance: ['system', 'light', 'dark'].includes(value.appearance) ? value.appearance : defaults.appearance,
      proxySort: ['original', 'delay', 'name'].includes(value.proxySort) ? value.proxySort : defaults.proxySort,
      proxyColumns: value.proxyColumns === 2 ? 2 : 1,
      testTimeout: [3000, 4500, 8000, 10000].includes(value.testTimeout) ? value.testTimeout : defaults.testTimeout,
      testUrl: /^https?:\/\//.test(value.testUrl) ? value.testUrl : defaults.testUrl,
      ipv6: value.ipv6 === true, allowLan: value.allowLan === true,
      dnsMode: value.dnsMode === 'fake-ip' ? 'fake-ip' : 'redir-host',
      logLevel: ['silent', 'error', 'warning', 'info', 'debug'].includes(value.logLevel) ? value.logLevel : defaults.logLevel
    };
  }

  static async load(context: common.Context): Promise<AppPreferences> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, { name: 'app_preferences' });
      const raw: string = await store.get('settings', '') as string;
      return raw.length > 0 ? AppPreferencesService.normalize(JSON.parse(raw) as AppPreferences) : defaultAppPreferences();
    } catch (err) {
      return defaultAppPreferences();
    }
  }

  static async save(context: common.Context, value: AppPreferences): Promise<void> {
    const store: preferences.Preferences = await preferences.getPreferences(context, { name: 'app_preferences' });
    await store.put('settings', JSON.stringify(AppPreferencesService.normalize(value)));
    await store.flush();
  }
}
