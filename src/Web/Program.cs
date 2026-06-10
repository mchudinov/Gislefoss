using Agent;
using Library;
using Serilog;
using Serilog.Debugging;
using Serilog.Events;
using MudBlazor.Services;

namespace Web;

public class Program
{
    public static void Main(string[] args)
    {
        Serilog.Log.Logger = new LoggerConfiguration()
                    .MinimumLevel.Override("Default", LogEventLevel.Debug)
                    .Enrich.FromLogContext()
                    .WriteTo.Console()
                    .CreateBootstrapLogger();

        SelfLog.Enable(Console.Error);

        try
        {
            var applicationStartTime = DateTimeOffset.UtcNow;
            Serilog.Log.Logger.Information("Web is running");
            Serilog.Log.Logger.Debug($".NET Version: {Environment.Version}");
            Serilog.Log.Logger.Debug("► Environment variables");
            Environment.GetEnvironmentVariables().OutputEnvironmentVariables();

            var enviroment = Environment.GetEnvironmentVariable("DOTNET_ENVIRONMENT");
            var configuration = new ConfigurationBuilder()
                .AddJsonFile("appsettings.json")
                .AddJsonFile($"appsettings.{enviroment}.json", optional: true)
                .AddEnvironmentVariables()
                .Build();
            var settings = configuration.GetRequiredSection("Settings").Get<Settings>() ?? throw new InvalidOperationException("Settings configuration section is missing or invalid.");

            Serilog.Log.Logger.Information("► Final configuration");
            configuration.AllConfigurationKeys().LogStrings();

            var builder = WebApplication.CreateBuilder(args);

            var logger = new LoggerConfiguration()
                .ReadFrom.Configuration(builder.Configuration)
                .Enrich.FromLogContext()
                .CreateLogger();
            builder.Logging.ClearProviders();
            builder.Logging.AddSerilog(logger);

            builder.AddOpenTelemetry();

            builder.Services.AddRazorComponents()
                .AddInteractiveServerComponents();

            builder.Services.AddMudServices();

            builder.Services.AddSingleton<Settings>(settings);

            builder.Services.AddMeteorologistAgent(builder.Configuration);

            var app = builder.Build();

            // The persona now lives server-side on the persistent agent (provisioned by Bicep); the
            // app retrieves the agent lazily by id (Settings:Agent:AgentId) on the first chat turn.
            // No boot-time Foundry contact — the UI prerenders without an agent configured.

            if (!app.Environment.IsDevelopment())
            {
                app.UseDeveloperExceptionPage();
            }
            else
            {
                app.UseExceptionHandler("/Error");
                app.UseHsts();
            }

            app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
            app.UseRouting();
            app.UseAntiforgery();
            app.UseAuthorization();
            app.MapStaticAssets();
            app.MapDefaultEndpoints(applicationStartTime);

            app.MapRazorComponents<Web.Components.App>()
                .AddInteractiveServerRenderMode();

            app.MapGet("/info", () => """
                    /livez liveness check
                    /uptime uptime statistic
                    """);

            app.Run();
        }
        catch (Exception ex)
        {
            Serilog.Log.Fatal(ex, "Web worker process terminated unexpectedly.");
        }
        finally
        {
            Serilog.Log.Information("Shut down complete.");
            Serilog.Log.CloseAndFlush();
        }
    }
}
