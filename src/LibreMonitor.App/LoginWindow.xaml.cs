using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using System.Windows.Input;
using System.Windows.Navigation;
using LibreMonitor.Core;

namespace LibreMonitor.App;

public partial class LoginWindow : Window
{
    private readonly LibreLinkUpClient _client;

    public (string Email, string Password)? Result { get; private set; }

    public LoginWindow(LibreLinkUpClient client)
    {
        InitializeComponent();
        _client = client;
        Loaded += (_, _) => EmailBox.Focus();
    }

    // Opens the link in the default browser. Only the fixed address in the XAML can reach this.
    private void Link_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }

    private void PasswordBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) SignIn_Click(sender, e);
    }

    private async void SignIn_Click(object sender, RoutedEventArgs e)
    {
        var email = EmailBox.Text.Trim();
        var password = PasswordBox.Password;
        if (email.Length == 0 || password.Length == 0)
        {
            ShowError("Enter both the email and the password.");
            return;
        }

        SignInButton.IsEnabled = false;
        ErrorText.Visibility = Visibility.Collapsed;
        try
        {
            // Validate now so a typo is reported here rather than on the main window.
            await _client.LoginAsync(email, password);
            Result = (email, password);
            DialogResult = true;
        }
        catch (LibreLinkUpException ex)
        {
            ShowError(ex.Message);
        }
        catch (HttpRequestException)
        {
            ShowError("Could not reach LibreView. Check your internet connection.");
        }
        finally
        {
            SignInButton.IsEnabled = true;
        }
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
