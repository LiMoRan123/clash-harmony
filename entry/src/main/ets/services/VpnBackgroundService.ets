import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { RuntimeDiagnostics } from './RuntimeDiagnostics';

export class VpnBackgroundService {
  private static context?: common.UIAbilityContext;
  private static desired: boolean = false;
  private static active: boolean = false;
  private static userCancelled: boolean = false;
  private static task?: Promise<void>;
  private static notificationId: number = -1;
  private static taskId: number = -1;
  private static lastUpdate: number = 0;
  private static lastBytes: number = -1;
  private static notificationTask?: Promise<void>;
  private static cancelListener = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (!VpnBackgroundService.active || info.id !== VpnBackgroundService.taskId) { return }
    VpnBackgroundService.active = false;
    VpnBackgroundService.notificationId = -1;
    VpnBackgroundService.userCancelled = info.reason === 1 || info.reason === 3;
    VpnBackgroundService.report('后台任务已取消，原因码 ' + info.reason);
    // Respect user cancellation. System cancellations are retried only when
    // the application next enters the foreground, never in a restart loop.
  };

  static configure(context: common.UIAbilityContext): void {
    if (VpnBackgroundService.context) { return }
    VpnBackgroundService.context = context;
    try { backgroundTaskManager.on('continuousTaskCancel', VpnBackgroundService.cancelListener) }
    catch (err) { VpnBackgroundService.report('后台任务取消监听不可用') }
  }

  private static report(message: string): void {
    AppStorage.setOrCreate<string>('vpnBackgroundStatus', message);
    const context = VpnBackgroundService.context;
    if (context) { RuntimeDiagnostics.append(context, 'ui', message) }
  }

  static setEnabled(enabled: boolean): Promise<void> {
    if (enabled && !VpnBackgroundService.desired) { VpnBackgroundService.userCancelled = false }
    VpnBackgroundService.desired = enabled;
    if (!VpnBackgroundService.task) {
      VpnBackgroundService.task = VpnBackgroundService.reconcile().finally(() => {
        VpnBackgroundService.task = undefined;
      });
    }
    return VpnBackgroundService.task;
  }

  static onForeground(): void {
    if (VpnBackgroundService.desired && !VpnBackgroundService.userCancelled) {
      VpnBackgroundService.setEnabled(true);
    }
  }

  private static async reconcile(): Promise<void> {
    const context = VpnBackgroundService.context;
    if (!context || VpnBackgroundService.userCancelled) { return }
    while (VpnBackgroundService.active !== VpnBackgroundService.desired) {
      try {
        if (VpnBackgroundService.desired) {
          const agent: WantAgent = await wantAgent.getWantAgent({
            wants: [{ bundleName: 'io.github.clashharmony.app', abilityName: 'EntryAbility' }],
            actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
            wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
          });
          if (!VpnBackgroundService.desired) { return }
          const info = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
          VpnBackgroundService.active = true;
          VpnBackgroundService.notificationId = info.notificationId;
          VpnBackgroundService.taskId = info.continuousTaskId ?? -1;
          VpnBackgroundService.lastUpdate = 0;
          VpnBackgroundService.lastBytes = -1;
          VpnBackgroundService.report('VPN 后台数据传输任务已开启');
        } else {
          // Complete a queued notification before cancelling its owning task;
          // otherwise a late publish could outlive the disconnect operation.
          if (VpnBackgroundService.notificationTask) { await VpnBackgroundService.notificationTask }
          await backgroundTaskManager.stopBackgroundRunning(context);
          VpnBackgroundService.active = false;
          VpnBackgroundService.notificationId = -1;
          VpnBackgroundService.report('VPN 后台任务已结束');
        }
      } catch (err) {
        VpnBackgroundService.report('后台任务操作失败，错误码 ' + (err as BusinessError).code);
        return;
      }
    }
  }

  static updateTraffic(download: number, upload: number): void {
    if (!VpnBackgroundService.active || !VpnBackgroundService.desired || VpnBackgroundService.notificationId < 0 ||
      VpnBackgroundService.notificationTask ||
      !Number.isFinite(download) || !Number.isFinite(upload) || download < 0 || upload < 0) { return }
    const bytes: number = Math.floor(download + upload);
    const now: number = Date.now();
    if (bytes === VpnBackgroundService.lastBytes || now - VpnBackgroundService.lastUpdate < 30000) { return }
    VpnBackgroundService.lastUpdate = now;
    VpnBackgroundService.lastBytes = bytes;
    // VPN traffic has no finite completion percentage. Report the actual
    // cumulative KiB as a non-percentage progress value, never synthetic ticks.
    const transferred: number = Math.floor(bytes / 1024);
    const text: string = '已传输 ' + (bytes / 1048576).toFixed(1) + ' MB';
    const request: notificationManager.NotificationRequest = {
      id: VpnBackgroundService.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: '喵连 VPN', text: text,
          progress: { currentValue: transferred, isPercentage: false } }
      },
      template: { name: 'downloadTemplate', data: {
        title: 'VPN 数据传输', fileName: text, progressValue: transferred,
        progressMaxValue: 2147483647, isProgressIndeterminate: true
      } }
    };
    try {
      VpnBackgroundService.notificationTask = notificationManager.publish(request).catch((err: BusinessError) => {
        VpnBackgroundService.report('VPN 后台通知更新失败，错误码 ' + err.code);
      }).finally(() => {
        VpnBackgroundService.notificationTask = undefined;
      });
    } catch (err) { VpnBackgroundService.report('VPN 后台通知更新失败') }
  }
}
