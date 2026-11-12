using System.Diagnostics;
using System.Reflection;

namespace Xunit;

// Minimal stand-in for xUnit (no NuGet feed in the build sandbox). Same attribute and Assert names,
// so test files are written exactly as they would be against the real package.

[AttributeUsage(AttributeTargets.Method)] public class FactAttribute : Attribute { }
[AttributeUsage(AttributeTargets.Method)] public sealed class TheoryAttribute : FactAttribute { }

[AttributeUsage(AttributeTargets.Method, AllowMultiple = true)]
public sealed class InlineDataAttribute(params object?[] data) : Attribute
{
    public object?[] Data { get; } = data;
}

public sealed class AssertFailedException(string message) : Exception(message);

public static class Assert
{
    public static void Equal<T>(T expected, T actual)
    {
        // Like xUnit: two collections are equal when their items are equal, in order.
        if (expected is System.Collections.IEnumerable e && actual is System.Collections.IEnumerable a && expected is not string)
        {
            var left = e.Cast<object?>().ToList();
            var right = a.Cast<object?>().ToList();
            if (left.Count != right.Count || left.Where((item, i) => !Equals(item, right[i])).Any())
                throw new AssertFailedException($"Assert.Equal failed. Collections differ (expected {left.Count} items, actual {right.Count})");
            return;
        }
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new AssertFailedException($"Assert.Equal failed. Expected: <{expected}>  Actual: <{actual}>");
    }

    public static void NotEqual<T>(T notExpected, T actual)
    {
        if (EqualityComparer<T>.Default.Equals(notExpected, actual))
            throw new AssertFailedException($"Assert.NotEqual failed. Both were <{actual}>");
    }

    public static void True(bool condition, string? message = null)
    {
        if (!condition) throw new AssertFailedException(message ?? "Assert.True failed");
    }

    public static void Empty<T>(IEnumerable<T> items)
    {
        var list = items.ToList();
        if (list.Count > 0) throw new AssertFailedException($"Assert.Empty failed. Had {list.Count}: {string.Join(" | ", list)}");
    }

    public static T Single<T>(IEnumerable<T> items)
    {
        var list = items.ToList();
        if (list.Count != 1) throw new AssertFailedException($"Assert.Single failed. Had {list.Count}: {string.Join(" | ", list)}");
        return list[0];
    }

    public static T Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T ex) { return ex; }
        catch (Exception ex) { throw new AssertFailedException($"Assert.Throws failed. Expected {typeof(T).Name}, got {ex.GetType().Name}: {ex.Message}"); }
        throw new AssertFailedException($"Assert.Throws failed. Expected {typeof(T).Name}, nothing was thrown");
    }
}

/// <summary>Discovers [Fact] and [Theory] methods; each case runs on a fresh instance of its class.</summary>
public static class XunitLiteRunner
{
    public static int Main()
    {
        var cases = Assembly.GetExecutingAssembly().GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance).Select(m => (Type: t, Method: m)))
            .Where(x => x.Method.GetCustomAttribute<FactAttribute>() is not null)
            .OrderBy(x => x.Type.Name).ThenBy(x => x.Method.Name)
            .SelectMany(x =>
            {
                var rows = x.Method.GetCustomAttributes<InlineDataAttribute>().Select(d => d.Data).ToList();
                return rows.Count == 0
                    ? [(x.Type, x.Method, Args: (object?[]?)null)]
                    : rows.Select(r => (x.Type, x.Method, Args: (object?[]?)r));
            })
            .ToList();

        int failed = 0;
        var clock = Stopwatch.StartNew();
        foreach (var (type, method, args) in cases)
        {
            var label = $"{type.Name}.{method.Name}" + (args is null ? "" : $"({string.Join(", ", args)})");
            try
            {
                method.Invoke(Activator.CreateInstance(type), args);
                Console.WriteLine($"  PASS  {label}");
            }
            catch (TargetInvocationException ex)
            {
                failed++;
                Console.WriteLine($"  FAIL  {label}\n        {ex.InnerException?.Message}");
            }
        }

        Console.WriteLine($"\n{cases.Count - failed}/{cases.Count} tests passed in {clock.ElapsedMilliseconds} ms");
        return failed == 0 ? 0 : 1;
    }
}
