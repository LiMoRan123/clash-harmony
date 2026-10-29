import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { VpnBackgroundService } from '../services/VpnBackgroundService';
import { RuntimeDiagnostics } from '../services/RuntimeDiagnostics';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashHarmony';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
    VpnBackgroundService.configure(this.context);
    RuntimeDiagnostics.append(this.context, 'ui', '应用创建，上次退出原因码 ' + launchParam.lastExitReason);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
    RuntimeDiagnostics.append(this.context, 'ui', 'UIAbility destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Main page loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Window stage destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility foreground');
    RuntimeDiagnostics.append(this.context, 'ui', '进入前台');
    AppStorage.setOrCreate<boolean>('vpnAppForeground', true);
    VpnBackgroundService.onForeground();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility background');
    RuntimeDiagnostics.append(this.context, 'ui', '进入后台');
    AppStorage.setOrCreate<boolean>('vpnAppForeground', false);
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
    RuntimeDiagnostics.append(this.context, 'ui', '内存压力等级 ' + level);
  }
}

