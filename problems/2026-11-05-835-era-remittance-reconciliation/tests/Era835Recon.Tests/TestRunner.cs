using System.Diagnostics;
using System.Reflection;

namespace Era835Recon.Tests;

/// <summary>Marks a public instance method as a test (same idea as xUnit's [Fact]).</summary>
[AttributeUsage(AttributeTargets.Method)]
public sealed class FactAttribute : Attribute { }

public sealed class AssertionException(string message) : Exception(message);

/// <summary>Minimal assertions, named like xUnit's so the tests read the same.</summary>
public static class Assert
{
    public static void Equal<T>(T expected, T actual, string? because = null)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new AssertionException($"Expected <{expected}> but was <{actual}>{(because is null ? "" : $" ({because})")}");
    }

    public static void True(bool condition, string message = "Expected true")
    {
        if (!condition) throw new AssertionException(message);
    }

    public static void Empty<T>(IEnumerable<T> items)
    {
        var list = items.ToList();
        if (list.Count != 0) throw new AssertionException($"Expected empty but had {list.Count}: {string.Join(" | ", list)}");
    }

    public static T Single<T>(IEnumerable<T> items)
    {
        var list = items.ToList();
        if (list.Count != 1) throw new AssertionException($"Expected exactly one item but had {list.Count}: {string.Join(" | ", list)}");
        return list[0];
    }

    public static TException Throws<TException>(Action action) where TException : Exception
    {
        try { action(); }
        catch (TException ex) { return ex; }
        catch (Exception ex) { throw new AssertionException($"Expected {typeof(TException).Name} but got {ex.GetType().Name}"); }
        throw new AssertionException($"Expected {typeof(TException).Name} but nothing was thrown");
    }
}

/// <summary>Finds every [Fact] in this assembly, runs it in a fresh class instance, and reports.</summary>
public static class TestRunner
{
    public static int Main()
    {
        var facts = Assembly.GetExecutingAssembly().GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance)
                .Where(m => m.GetCustomAttribute<FactAttribute>() is not null)
                .Select(m => (Type: t, Method: m)))
            .OrderBy(f => f.Type.Name).ThenBy(f => f.Method.Name)
            .ToList();

        int failed = 0;
        var clock = Stopwatch.StartNew();
        foreach (var (type, method) in facts)
        {
            try
            {
                method.Invoke(Activator.CreateInstance(type), null);
                Console.WriteLine($"  PASS  {type.Name}.{method.Name}");
            }
            catch (TargetInvocationException ex)
            {
                failed++;
                Console.WriteLine($"  FAIL  {type.Name}.{method.Name}\n        {ex.InnerException?.Message}");
            }
        }

        Console.WriteLine($"\n{facts.Count - failed}/{facts.Count} tests passed in {clock.ElapsedMilliseconds} ms");
        return failed == 0 ? 0 : 1;
    }
}
