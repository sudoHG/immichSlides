"""Static declarations from supplied source text, never from candidate imports."""

from __future__ import annotations

import ast
import fnmatch
import re
from pathlib import Path

from ci_summary import ContractError, fields, identity_key, require, sha, test_identity, validate_test_identity
from ui_test_inventory import blank_comments_and_strings, line_platforms, matching_brace, parse_ui_tests

# Explicit Python 3.9 names keep classification independent of the host Python.
BUILTIN_BASES = frozenset("""
object type bool int float complex str bytes bytearray list tuple dict set frozenset
memoryview range slice property classmethod staticmethod super
BaseException Exception ArithmeticError AssertionError AttributeError BlockingIOError
BrokenPipeError BufferError ChildProcessError ConnectionAbortedError ConnectionError
ConnectionRefusedError ConnectionResetError EOFError EnvironmentError FileExistsError
FileNotFoundError FloatingPointError GeneratorExit IOError ImportError IndentationError
IndexError InterruptedError IsADirectoryError KeyError KeyboardInterrupt LookupError
MemoryError ModuleNotFoundError NameError NotADirectoryError NotImplementedError OSError
OverflowError PermissionError ProcessLookupError RecursionError ReferenceError RuntimeError
StopAsyncIteration StopIteration SyntaxError SystemError SystemExit TabError TimeoutError
TypeError UnboundLocalError UnicodeDecodeError UnicodeEncodeError UnicodeError
UnicodeTranslateError ValueError ZeroDivisionError Warning BytesWarning DeprecationWarning
FutureWarning ImportWarning PendingDeprecationWarning ResourceWarning RuntimeWarning
SyntaxWarning UnicodeWarning UserWarning
""".split())
STDLIB_BASE_MODULES = frozenset("""
abc argparse array ast asynchat asyncore asyncio atexit base64 bdb binascii bisect builtins bz2 calendar
cgi cgitb chunk cmd code codecs codeop collections colorsys compileall concurrent configparser
contextlib contextvars copy copyreg crypt csv ctypes curses dataclasses datetime dbm decimal
difflib dis distutils doctest email encodings enum errno faulthandler fcntl filecmp fileinput fnmatch
fractions ftplib functools gc genericpath getopt getpass gettext glob graphlib grp gzip hashlib heapq hmac
html http imaplib importlib inspect io ipaddress itertools json keyword linecache locale
logging lzma mailbox mailcap marshal math mimetypes mmap modulefinder msilib msvcrt multiprocessing
netrc nis nntplib ntpath nturl2path numbers opcode operator optparse os parser pathlib pdb pickle pickletools pipes pkgutil
platform plistlib poplib posix posixpath pprint profile pstats pty pwd py_compile pyclbr pydoc queue quopri
random re readline reprlib resource rlcompleter runpy sched secrets select selectors shelve
shlex shutil signal site smtpd smtplib sndhdr socket socketserver spwd sqlite3 ssl stat statistics
string stringprep struct subprocess sunau symbol symtable sys sysconfig syslog tabnanny tarfile
telnetlib tempfile termios textwrap threading time timeit tkinter token tokenize trace traceback
tracemalloc tty turtle types typing unicodedata urllib uu uuid venv warnings wave weakref
webbrowser winreg winsound wsgiref xdrlib xml xmlrpc zipapp zipfile zipimport zlib
""".split())


def ordered(identities):
    found = {}
    for identity in identities:
        validate_test_identity(identity)
        found[identity_key(identity)] = identity
    return sorted(found.values(), key=lambda item: (item["kind"], item["key"], identity_key(item)))


def removed_tests(base_population, tested_population, *, base_sha):
    """Use the admitted PR base, never a later main population."""
    fields(base_population, {"base_sha", "identities"}, "base population")
    sha(base_population["base_sha"])
    sha(base_sha)
    require(base_population["base_sha"] == base_sha, "population differs from admitted base SHA")
    identities = base_population["identities"]
    require(isinstance(identities, list), "base population identities must be an array")
    validated = ordered(identities)
    require(len(validated) == len(identities), "duplicate base population identity")
    tested = {identity_key(item) for item in tested_population}
    return [item for item in validated if identity_key(item) not in tested]


def dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return dotted(node.value) + "." + node.attr
    if isinstance(node, ast.Subscript):
        return dotted(node.value)
    raise ContractError("dynamic Python class base cannot be enumerated statically")


def python_identities(files, *, discovery_pattern="test_*"):
    """Map importable module names to source; follow aliases, mixins and C3 MRO.

    The caller supplies all local modules, including non-discovered mixin modules.
    Unsupported discovery hooks, conditional bindings and unresolved bases in test
    modules fail closed. Unrelated helper classes need not be test-discoverable.
    Functions' bodies are never evaluated and nested fixture classes are not discovered.
    """
    modules, classes = {}, {}

    def discovered(module):
        return fnmatch.fnmatchcase(module.rsplit(".", 1)[-1], discovery_pattern)

    def target_names(target):
        if isinstance(target, ast.Name):
            return [target.id]
        if isinstance(target, (ast.Tuple, ast.List)):
            return [name for element in target.elts for name in target_names(element)]
        if isinstance(target, (ast.Attribute, ast.Subscript)):
            return target_names(target.value)
        return []

    def assignment_targets(node):
        return node.targets if isinstance(node, (ast.Assign, ast.Delete)) else [node.target]

    def validate_bindings(module, tree):
        # Final module bindings are safe only when base dependencies are bound once,
        # before use. Reject unsupported control flow rather than simulating Python.
        events = {}
        for node in tree.body:
            dependencies = []
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                names = [alias.asname or (alias.name.split('.')[0] if isinstance(node, ast.Import) else alias.name)
                         for alias in node.names]
            elif isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                names = [node.name]
            elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.Delete)):
                names = [name for target in assignment_targets(node) for name in target_names(target)]
                if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                    try:
                        dependencies = [dotted(node.value).split('.')[0]]
                    except ContractError:
                        pass
            else:
                continue
            for name in names:
                events.setdefault(name, []).append((node.lineno, dependencies))

        used_bases = set()

        def check_base(name, before, visiting=()):
            used_bases.add(name)
            require(name not in visiting, f"{module}: cyclic base binding: {name}")
            writes = events.get(name, [])
            require(len(writes) <= 1, f"{module}: repeated base binding: {name}")
            if writes:
                line, dependencies = writes[0]
                require(line < before, f"{module}: base binding occurs after use: {name}")
                for dependency in dependencies:
                    check_base(dependency, line, (*visiting, name))

        for node in tree.body:
            if isinstance(node, ast.ClassDef):
                for base in node.bases:
                    check_base(dotted(base).split('.')[0], node.lineno)

        def check_conditional(node):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                return
            require(not isinstance(node, (ast.Import, ast.ImportFrom, ast.ClassDef, ast.For, ast.NamedExpr))
                    and not (isinstance(node, ast.With) and any(item.optional_vars for item in node.items)),
                    f"{module}: conditional discovery binding is unsupported")
            if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.Delete)):
                targets = assignment_targets(node)
                names = {name for target in targets for name in target_names(target)}
                harmless = (isinstance(node, (ast.Assign, ast.AnnAssign)) and isinstance(node.value, ast.Constant)
                            and all(isinstance(target, ast.Name) for target in targets)
                            and not names.intersection(used_bases | set(events)))
                require(harmless, f"{module}: conditional discovery binding is unsupported")
            for child in ast.iter_child_nodes(node):
                check_conditional(child)

        for node in tree.body:
            if isinstance(node, (ast.If, ast.Try, ast.For, ast.While, ast.With)):
                check_conditional(node)

    for module, source in files.items():
        try:
            tree = ast.parse(source, filename=module)
        except SyntaxError as error:
            raise ContractError(f"{module}: invalid Python syntax") from error
        if discovered(module):
            validate_bindings(module, tree)
        bindings = {}
        for node in tree.body:
            if isinstance(node, ast.Import):
                for alias in node.names:
                    bindings[alias.asname or alias.name.split('.')[0]] = alias.name if alias.asname else alias.name.split('.')[0]
            elif isinstance(node, ast.ImportFrom):
                prefix = node.module or ""
                if node.level:
                    parts = module.split(".")[:-node.level]
                    prefix = ".".join(parts + ([prefix] if prefix else []))
                for alias in node.names:
                    require(alias.name != "*" or not discovered(module), f"{module}: wildcard imports obscure discovery")
                    bindings[alias.asname or alias.name] = prefix + "." + alias.name
            elif isinstance(node, ast.ClassDef):
                name = module + "." + node.name
                require(name not in classes, f"{name}: duplicate class declaration")
                classes[name] = node
                bindings[node.name] = name
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Name):
                        try:
                            alias = dotted(node.value)
                        except ContractError:
                            alias = target.id
                        bindings[target.id] = module + "." + alias
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                require(node.name != "load_tests" or not discovered(module), f"{module}: load_tests is dynamic discovery")
                bindings[node.name] = module + "." + node.name
        modules[module] = bindings

    terminals = {"unittest.TestCase", "unittest.case.TestCase", "unittest.IsolatedAsyncioTestCase",
                 "unittest.async_case.IsolatedAsyncioTestCase", "doctest.DocTestCase"}

    def non_test_terminal(name):
        root, separator, _ = name.partition(".")
        return bool(separator and root in STDLIB_BASE_MODULES and not any(
            name == module or name.startswith(module + ".") for module in modules))

    def resolve(name, seen=()):
        if name in classes or name in terminals or non_test_terminal(name):
            return name
        require(name not in seen, f"cyclic Python alias: {name}")
        for module in sorted(modules, key=len, reverse=True):
            if name.startswith(module + "."):
                suffix = name[len(module) + 1:]
                first, _, rest = suffix.partition(".")
                bound = modules[module].get(first)
                if bound is None and suffix in BUILTIN_BASES:
                    return "builtins." + suffix
                if bound is not None:
                    target = bound + ("." + rest if rest else "")
                    if target != name:
                        return resolve(target, (*seen, name))
        return name

    cache = {}

    def mro(name, visiting=()):
        if name in cache:
            return cache[name]
        require(name not in visiting, f"cyclic Python inheritance: {name}")
        if name in terminals or non_test_terminal(name):
            return [name]
        require(name in classes, f"unresolved Python test base: {name}")
        node = classes[name]
        module = name.rsplit(".", 1)[0]
        bases = [resolve(module + "." + dotted(base)) for base in node.bases]
        sequences = [list(mro(base, (*visiting, name))) for base in bases] + [list(bases)]
        result = [name]
        while any(sequences):
            sequences = [sequence for sequence in sequences if sequence]
            head = next((seq[0] for seq in sequences if not any(seq[0] in other[1:] for other in sequences)), None)
            require(head is not None, f"inconsistent Python MRO: {name}")
            result.append(head)
            for sequence in sequences:
                if sequence[0] == head:
                    sequence.pop(0)
        cache[name] = result
        return result

    def is_test_case(name, visiting=()):
        if name in terminals:
            return True
        if name not in classes:
            return False
        require(name not in visiting, f"cyclic Python inheritance: {name}")
        module = name.rsplit(".", 1)[0]
        inherited = []
        for base in classes[name].bases:
            try:
                target = resolve(module + "." + dotted(base))
            except ContractError:
                if discovered(module):
                    raise
                continue
            if discovered(module):
                require(target in classes or target in terminals or non_test_terminal(target),
                        f"{name}: unresolved Python test base: {target}")
            inherited.append(is_test_case(target, (*visiting, name)))
        return any(inherited)

    # Validate every class declared in a discovered module, even when its base
    # never resolves to TestCase. Otherwise a broken alias can erase a whole suite.
    for name in classes:
        if discovered(name.rsplit(".", 1)[0]):
            is_test_case(name)

    identities = []
    seen_classes = set()
    for module, bindings in modules.items():
        if not discovered(module):
            continue
        for bound in bindings.values():
            name = resolve(bound)
            if name in seen_classes or not is_test_case(name):
                continue
            seen_classes.add(name)
            methods = {}
            for ancestor in mro(name):
                if ancestor not in classes:
                    continue
                local = {}
                for member in classes[ancestor].body:
                    if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        local[member.name] = True
                    elif isinstance(member, (ast.Assign, ast.AnnAssign)):
                        targets = member.targets if isinstance(member, ast.Assign) else [member.target]
                        for target in targets:
                            if isinstance(target, ast.Name):
                                require(not target.id.startswith("test") or isinstance(member.value, ast.Constant),
                                        f"{ancestor}: dynamically assigned test method {target.id}")
                                local[target.id] = False
                    elif isinstance(member, (ast.If, ast.Try, ast.For)):
                        require(not any(isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and child.name.startswith("test")
                                        for child in ast.walk(member)), f"{ancestor}: conditional test method")
                for method, callable_member in local.items():
                    methods.setdefault(method, callable_member)
            identities.extend(test_identity("python", name + "." + method)
                              for method, callable_member in methods.items() if method.startswith("test") and callable_member)
    return ordered(identities)


def xctest_identities(files, platform, *, kind):
    require(platform in {"ios", "tvos"}, "unsupported platform")
    try:
        classes, methods, errors, _strict = parse_ui_tests(files, allow_non_xctest_functions=kind == "swift")
    except ValueError as error:
        raise ContractError(str(error)) from error
    require(not errors, "; ".join(errors))
    return ordered(test_identity(kind, f"{owner}/{method}", platform=platform)
                   for owner, members in methods.items() for method, platforms in members.items()
                   if platform in platforms and platform in classes[owner])


def ui_identities(files, platform):
    return xctest_identities(files, platform, kind="ui")


TYPE_RE = re.compile(r"\b(struct|class|enum|extension)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)[^{}]*\{")
ATTRIBUTE_RE = re.compile(r"@\s*((?:`?[A-Za-z_]\w*`?\s*\.\s*)*`?[A-Za-z_]\w*`?)")
FUNCTION_RE = re.compile(r"\bfunc\s+(`[^`]+`|[A-Za-z_]\w*)\s*(?:<[^>{}]*>)?\s*\(")


def conditional_code(source, platform):
    code = blank_comments_and_strings(source)
    errors = []
    allowed = line_platforms(code, errors)
    stack = []
    for line in code.splitlines():
        directive = re.match(r"\s*#(if|elseif|else|endif)\b", line)
        if directive:
            keyword = directive[1]
            if keyword == "if":
                stack.append(False)
            else:
                require(bool(stack), "unmatched Swift conditional directive")
                if keyword == "endif":
                    stack.pop()
                else:
                    require(not stack[-1], "Swift branch after #else")
                    if keyword == "else":
                        stack[-1] = True
    require(not stack, "unterminated Swift conditional directive")
    require(not errors, "; ".join(errors))
    return "\n".join(line if platform in platforms and not re.match(r"\s*#(?:if|else|elseif|endif)\b", line)
                     else " " * len(line) for line, platforms in zip(code.split("\n"), allowed))


def swift_identities(files, platform):
    """Enumerate @Test functions, including implicit suites and cross-file extensions.

    Keys use Type/function (or function for a top-level test), without arguments.
    Nested suite names are qualified. Unknown conditionals/declarations are errors.
    """
    require(platform in {"ios", "tvos"}, "unsupported platform")
    parsed, declarations = [], set()
    for filename, source in files.items():
        code = conditional_code(source, platform)
        scopes = []
        try:
            for match in TYPE_RE.finditer(code):
                start = match.end() - 1
                close = matching_brace(code, start)
                parents = [scope for scope in scopes if scope[0] < match.start() < scope[1]]
                parent = max(parents, default=None, key=lambda scope: scope[0])
                local = bool(parent and (parent[4] or code.count("{", parent[0] + 1, match.start()) != code.count("}", parent[0] + 1, match.start())))
                name = (parent[2] + "." if parent else "") + match[2]
                scopes.append((start, close, name, match[1], local))
                if match[1] != "extension" and not local:
                    declarations.add(name)
        except ValueError as error:
            raise ContractError(f"{filename}: {error}") from error
        parsed.append((filename, code, scopes))

    # The unit target mixes Swift Testing suites and XCTestCase classes.
    # Reuse the UI parser so compiled unit methods cannot disappear from coverage.
    found = {identity["key"]: identity for identity in xctest_identities(
        {filename: code for filename, code, _ in parsed}, platform, kind="swift")}
    for filename, code, scopes in parsed:
        for attribute in ATTRIBUTE_RE.finditer(code):
            name = re.sub(r"\s|`", "", attribute[1])
            if not {"Test", "Suite"}.intersection(name.split(".")):
                continue
            require(name in {"Test", "Suite", "Testing.Test", "Testing.Suite"},
                    f"{filename}: unsupported test attribute @{name}")
            position = attribute.end()
            if code[position:].lstrip().startswith("("):
                position = code.index("(", position)
                depth = 1
                position += 1
                while position < len(code) and depth:
                    depth += (code[position] == "(") - (code[position] == ")")
                    position += 1
                require(depth == 0, f"{filename}: unbalanced Swift attribute")
            remainder = code[position:]
            if name.rsplit(".", 1)[-1] == "Suite":
                match = TYPE_RE.search(remainder)
                require(match is not None and not re.search(r"[{};]|\bfunc\b", remainder[:match.start()]),
                        f"{filename}: @Suite without a type declaration")
                continue
            function = FUNCTION_RE.search(remainder)
            require(function is not None, f"{filename}: @Test without function")
            prefix = remainder[:function.start()]
            require(not re.search(r"[{};<>]|\b(var|let|struct|class|enum|actor|extension)\b", prefix)
                    and not any({"Test", "Suite"}.intersection(re.sub(r"\s|`", "", match[1]).split("."))
                                for match in ATTRIBUTE_RE.finditer(prefix)),
                    f"{filename}: unsupported @Test declaration")
            offset = position + function.start()
            owners = [scope for scope in scopes if scope[0] < offset < scope[1]]
            owner = max(owners, default=None, key=lambda scope: scope[0])
            require(owner is None or not owner[4], f"{filename}: local @Test type is unsupported")
            start = owner[0] + 1 if owner else 0
            require(code.count("{", start, offset) == code.count("}", start, offset),
                    f"{filename}: local @Test function is unsupported")
            if owner and owner[3] == "extension":
                require(owner[2] in declarations, f"{filename}: unknown extended suite {owner[2]}")
            key = (owner[2] + "/" if owner else "") + function[1].strip("`")
            require(key not in found, f"{filename}: duplicate Swift function identity {key}")
            found[key] = test_identity("swift", key, platform=platform)
    return ordered(found.values())


def python_sources(root):
    """Read public Python source only; callers choose the tested tree directory."""
    root = Path(root)
    return {".".join(path.relative_to(root).with_suffix("").parts): path.read_text(encoding="utf-8")
            for path in sorted(root.rglob("*.py")) if "__pycache__" not in path.parts}
