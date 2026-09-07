import io.github.detekt.metrics.CognitiveComplexity;
import io.github.detekt.metrics.CyclomaticComplexity;
import io.github.detekt.metrics.LinesOfCodeKt;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import org.jetbrains.kotlin.cli.jvm.compiler.EnvironmentConfigFiles;
import org.jetbrains.kotlin.cli.jvm.compiler.KotlinCoreEnvironment;
import org.jetbrains.kotlin.com.intellij.openapi.Disposable;
import org.jetbrains.kotlin.com.intellij.openapi.util.Disposer;
import org.jetbrains.kotlin.com.intellij.psi.PsiElement;
import org.jetbrains.kotlin.com.intellij.psi.PsiErrorElement;
import org.jetbrains.kotlin.com.intellij.psi.util.PsiTreeUtil;
import org.jetbrains.kotlin.config.CompilerConfiguration;
import org.jetbrains.kotlin.psi.KtClassOrObject;
import org.jetbrains.kotlin.psi.KtFile;
import org.jetbrains.kotlin.psi.KtNamedFunction;
import org.jetbrains.kotlin.psi.KtPsiFactory;

/** 独立使用 detekt 自带的 Kotlin PSI 与指标；不参与 Android 编译。 */
class FunctionMetrics {
    record Metric(String path, String sourceSet, String name, int startLine, int endLine,
                  int physicalLines, int codeLines, int cyclomatic, int cognitive) {
        String csv() {
            return quote(path) + "," + quote(sourceSet) + "," + quote(name) + "," + startLine + ","
                + endLine + "," + physicalLines + "," + codeLines + "," + cyclomatic + "," + cognitive;
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("Expected: repository input-list output-csv");
        Disposable disposable = Disposer.newDisposable("kotlin-metrics");
        try {
            var environment = KotlinCoreEnvironment.createForProduction(disposable,
                new CompilerConfiguration(), EnvironmentConfigFiles.JVM_CONFIG_FILES);
            var factory = new KtPsiFactory(environment.getProject(), false);
            selfTest(factory);
            Path root = Path.of(args[0]).toAbsolutePath().normalize();
            List<Metric> metrics = new ArrayList<>();
            for (String relative : Files.readAllLines(Path.of(args[1]), StandardCharsets.UTF_8)) {
                Path file = root.resolve(relative).normalize();
                if (!file.startsWith(root)) throw new IllegalArgumentException("Input escapes repository");
                metrics.addAll(measure(factory, relative, Files.readString(file, StandardCharsets.UTF_8)));
            }
            metrics.sort(Comparator.comparingInt(Metric::physicalLines).reversed()
                .thenComparing(Metric::path).thenComparingInt(Metric::startLine));
            List<String> csv = new ArrayList<>();
            csv.add("path,sourceSet,name,startLine,endLine,physicalLines,codeLines,cyclomatic,cognitive");
            metrics.forEach(metric -> csv.add(metric.csv()));
            Files.write(Path.of(args[2]), csv, StandardCharsets.UTF_8);
            System.out.println("PASS: PSI regression checks; measured " + metrics.size() + " functions.");
        } finally {
            Disposer.dispose(disposable);
        }
    }

    static List<Metric> measure(KtPsiFactory factory, String path, String original) {
        // PSI 的换行要求 LF；先规范化文本，物理行号在 CRLF/LF 下保持一致。
        String text = original.replace("\r\n", "\n").replace('\r', '\n');
        if (text.startsWith("\uFEFF")) text = text.substring(1);
        KtFile file = factory.createFile(Path.of(path).getFileName().toString(), text);
        var errors = PsiTreeUtil.findChildrenOfType(file, PsiErrorElement.class);
        if (!errors.isEmpty()) {
            PsiErrorElement first = errors.iterator().next();
            throw new IllegalArgumentException(path + ":" + lineAt(text, first.getTextOffset())
                + ": Kotlin syntax error: " + first.getErrorDescription());
        }
        List<Metric> rows = new ArrayList<>();
        for (KtNamedFunction function : PsiTreeUtil.findChildrenOfType(file, KtNamedFunction.class)) {
            PsiElement keyword = function.getFunKeyword();
            if (keyword == null) throw new IllegalStateException("Missing fun keyword: " + path);
            int start = lineAt(text, keyword.getTextRange().getStartOffset());
            int end = lineAt(text, function.getTextRange().getEndOffset() - 1);
            rows.add(new Metric(path, sourceSet(path), qualifiedName(function), start, end, end - start + 1,
                LinesOfCodeKt.linesOfCode(function, file),
                CyclomaticComplexity.Companion.calculate(function, null),
                CognitiveComplexity.Companion.calculate(function)));
        }
        return rows;
    }

    static String sourceSet(String path) {
        String[] parts = path.split("/");
        for (int i = 0; i + 1 < parts.length; i++) {
            if (parts[i].equals("src")) return parts[i + 1];
        }
        return "other";
    }

    static String qualifiedName(KtNamedFunction function) {
        List<String> names = new ArrayList<>();
        for (PsiElement node = function; node != null; node = node.getParent()) {
            if (node instanceof KtNamedFunction fn) {
                names.add(0, fn.getName() == null ? "<anonymous>" : fn.getName());
            } else if (node instanceof KtClassOrObject owner) {
                names.add(0, owner.getName() == null ? "<anonymous-object>" : owner.getName());
            }
        }
        return String.join(".", names);
    }

    static int lineAt(String text, int offset) {
        int line = 1;
        for (int i = 0; i < offset; i++) if (text.charAt(i) == '\n') line++;
        return line;
    }

    static String quote(String value) {
        return "\"" + value.replace("\"", "\"\"") + "\"";
    }

    static void selfTest(KtPsiFactory factory) {
        // 包含误导性的括号、字符串模板、lambda、局部函数、表达式体、注释、重载和匿名函数。
        String fixture = String.join("\n",
            "class Fixture {",                                      // 1
            "    /** docs { } */",                                   // 2
            "    @Suppress(\"LongMethod\")",                         // 3
            "    fun outer(value: Boolean): String {",                // 4
            "        val braces = \"} { ${if (value) \"{\" else \"}\"}\"", // 5
            "        /* }",                                          // 6
            "           { */",                                       // 7
            "",                                                     // 8
            "        fun local() = \"}\"",                           // 9
            "        return listOf(braces).map { it + local() }.joinToString()", // 10
            "    }",                                                 // 11
            "    fun `expression name`() =",                          // 12
            "        \"{ }\"",                                       // 13
            "    fun overload() = 1",                                 // 14
            "    fun overload(x: Int) = x",                           // 15
            "    val callback = fun(x: Int): Int { return x }",        // 16
            "    fun branch(x: Boolean) {",                           // 17
            "        if (x) println(1)",                              // 18
            "    }",                                                 // 19
            "    fun raw() = \"\"\"",                                 // 20
            "}",                                                     // 21
            "{",                                                     // 22
            "\"\"\"",                                                 // 23
            "}");                                                    // 24
        List<Metric> rows = measure(factory, "src/main/Fixture.kt", fixture);
        require(rows.size() == 8, "AST must include nested, overloaded and anonymous functions");
        check(rows, "Fixture.outer", 4, 11, 6, 3, 2);
        check(rows, "Fixture.outer.local", 9, 9, 1, 1, 0);
        check(rows, "Fixture.expression name", 12, 13, 2, 1, 0);
        check(rows, "Fixture.<anonymous>", 16, 16, 1, 1, 0);
        check(rows, "Fixture.branch", 17, 19, 3, 2, 1);
        check(rows, "Fixture.raw", 20, 23, 4, 1, 0);
        require(rows.equals(measure(factory, "src/main/Fixture.kt", "\uFEFF" + fixture.replace("\n", "\r\n"))),
            "BOM and CRLF must preserve metrics");
        boolean rejected = false;
        try { measure(factory, "Broken.kt", "fun broken( { }"); }
        catch (IllegalArgumentException expected) { rejected = true; }
        require(rejected, "Syntax errors must fail instead of publishing a partial ranking");
    }

    static void check(List<Metric> rows, String name, int start, int end, int code, int cyclomatic, int cognitive) {
        Metric row = rows.stream().filter(candidate -> candidate.name.equals(name)).findFirst().orElseThrow();
        require(row.startLine == start && row.endLine == end && row.physicalLines == end - start + 1
            && row.codeLines == code && row.cyclomatic == cyclomatic && row.cognitive == cognitive,
            "Regression mismatch: " + row);
    }

    static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }
}
