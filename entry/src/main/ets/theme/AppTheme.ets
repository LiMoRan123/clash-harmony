// Material tonal surfaces shared by the full application. Resources follow the
// application's color mode, including sheets and nested tools.
export class AppTheme {
  static readonly contentMaxWidth: number = 640;
  static readonly gutter: number = 16;
  static readonly cardRadius: number = 24;
  static readonly rowRadius: number = 20;
  static readonly background: ResourceColor = $r('app.color.ui_background');
  static readonly surface: ResourceColor = $r('app.color.ui_surface');
  static readonly variant: ResourceColor = $r('app.color.ui_surface_variant');
  static readonly selectedSurface: ResourceColor = $r('app.color.ui_selected_surface');
  static readonly primary: ResourceColor = $r('app.color.ui_primary');
  static readonly onPrimary: ResourceColor = $r('app.color.ui_on_primary');
  static readonly primaryContainer: ResourceColor = $r('app.color.ui_primary_container');
  static readonly onPrimaryContainer: ResourceColor = $r('app.color.ui_on_primary_container');
  static readonly text: ResourceColor = $r('app.color.ui_text');
  static readonly muted: ResourceColor = $r('app.color.ui_muted');
  static readonly outline: ResourceColor = $r('app.color.ui_outline');
  static readonly success: ResourceColor = $r('app.color.ui_success');
  static readonly successContainer: ResourceColor = $r('app.color.ui_success_container');
  static readonly danger: ResourceColor = $r('app.color.ui_danger');
  static readonly dangerContainer: ResourceColor = $r('app.color.ui_danger_container');
  static readonly warning: ResourceColor = $r('app.color.ui_warning');
}
