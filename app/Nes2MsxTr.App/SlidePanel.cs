using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;

namespace Nes2MsxTr.App;

/// <summary>A panel with a rotated title tab on its left; clicking the tab shows / hides the content.</summary>
public class SlidePanel : ContentControl
{
    public static readonly StyledProperty<string> TitleProperty = AvaloniaProperty.Register<SlidePanel, string>(nameof(Title), "");
    public static readonly StyledProperty<bool> IsOpenProperty = AvaloniaProperty.Register<SlidePanel, bool>(nameof(IsOpen), true);

    public string Title { get => GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public bool IsOpen { get => GetValue(IsOpenProperty); set => SetValue(IsOpenProperty, value); }

    protected override Type StyleKeyOverride => typeof(SlidePanel);

    protected override void OnApplyTemplate(TemplateAppliedEventArgs e)
    {
        base.OnApplyTemplate(e);
        if (e.NameScope.Find<Button>("PART_Tab") is { } b) b.Click += (_, _) => IsOpen = !IsOpen;
    }
}
