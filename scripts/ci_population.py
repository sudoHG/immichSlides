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
    """Enumerate the documented declaration grammar without candidate execution.

    Test modules and their local test-class/MRO providers must satisfy the grammar.
    Function bodies are opaque; unrelated non-test helper classes are not discovered.
    """
    modules, classes, trees, events = {}, {}, {}, {}
    terminals = {"unittest.TestCase", "unittest.case.TestCase", "unittest.IsolatedAsyncioTestCase",
                 "unittest.async_case.IsolatedAsyncioTestCase", "doctest.DocTestCase"}

    def discovered(module):
        return fnmatch.fnmatchcase(module.rsplit(".", 1)[-1], discovery_pattern)

    def fail(module, node, message):
        filename = module.replace(".", "/") + ".py"
        raise ContractError(f"{filename}:{node.lineno}: {message}")

    def imports(module, node):
        if isinstance(node, ast.Import):
            return [(alias.asname or alias.name.split(".")[0],
                     alias.name if alias.asname else alias.name.split(".")[0]) for alias in node.names]
        prefix = node.module or ""
        if node.level:
            prefix = ".".join(module.split(".")[:-node.level] + ([prefix] if prefix else []))
        return [(alias.asname or alias.name, prefix + "." + alias.name) for alias in node.names]

    for module, source in files.items():
        try:
            tree = ast.parse(source, filename=module.replace(".", "/") + ".py")
        except SyntaxError as error:
            raise ContractError(f"{error.filename}:{error.lineno}: invalid Python syntax") from error
        trees[module] = tree
        bindings, writes = {}, {}
        for node in tree.body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                entries = imports(module, node)
            elif isinstance(node, ast.ClassDef):
                name = module + "." + node.name
                if name in classes:
                    fail(module, node, "duplicate class declaration")
                classes[name] = node
                entries = [(node.name, name)]
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                entries = [(node.name, module + "." + node.name)]
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                entries = []
                for target in targets:
                    if isinstance(target, ast.Name):
                        try:
                            value = dotted(node.value)
                        except ContractError:
                            value = target.id
                        entries.append((target.id, module + "." + value))
            else:
                continue
            for name, value in entries:
                bindings[name] = value
                writes.setdefault(name, []).append(node)
        modules[module], events[module] = bindings, writes

    def non_test_terminal(name):
        root, separator, _ = name.partition(".")
        return bool(separator and root in STDLIB_BASE_MODULES and not any(
            name == module or name.startswith(module + ".") for module in modules))

    def resolve(name, seen=()):
        if name in classes or name in terminals or non_test_terminal(name):
            return name
        if name in seen:
            module = next(module for module in modules if name.startswith(module + "."))
            fail(module, events[module][name[len(module) + 1:].split(".")[0]][0], "cyclic import or assignment alias")
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

    def bases(name):
        node, module = classes[name], name.rsplit(".", 1)[0]
        found = []
        for base in node.bases:
            try:
                target = resolve(module + "." + dotted(base))
            except ContractError:
                if discovered(module):
                    fail(module, base, "base must be a statically resolved name or attribute")
                continue
            found.append(target)
        return found

    def is_test_case(name, visiting=()):
        if name in terminals:
            return True
        if name not in classes:
            return False
        module, node = name.rsplit(".", 1)[0], classes[name]
        if name in visiting:
            fail(module, node, "cyclic Python inheritance")
        return any(is_test_case(base, (*visiting, name)) for base in bases(name))

    cache = {}

    def mro(name, visiting=()):
        if name in cache:
            return cache[name]
        if name in terminals or non_test_terminal(name):
            return [name]
        if name not in classes:
            raise ContractError("unresolved Python test base: " + name)
        module, node = name.rsplit(".", 1)[0], classes[name]
        if name in visiting:
            fail(module, node, "cyclic Python inheritance")
        parents = bases(name)
        for parent in parents:
            if parent not in classes and parent not in terminals and not non_test_terminal(parent):
                fail(module, node, "unresolved Python test base: " + parent)
        sequences = [list(mro(base, (*visiting, name))) for base in parents] + [list(parents)]
        result = [name]
        while any(sequences):
            sequences = [sequence for sequence in sequences if sequence]
            head = next((seq[0] for seq in sequences if not any(seq[0] in other[1:] for other in sequences)), None)
            if head is None:
                fail(module, node, "inconsistent Python MRO")
            result.append(head)
            for sequence in sequences:
                if sequence[0] == head:
                    sequence.pop(0)
        cache[name] = result
        return result

    # Include providers even when their final export was rebound or conditionally
    # declared. Looking only at final bindings would silently erase those classes.
    strict = {module for module in modules if discovered(module)}
    providers = set()
    for module, tree in trees.items():
        for node in tree.body:
            if isinstance(node, (ast.Import, ast.ImportFrom)) and any(
                    resolve(target) in terminals or is_test_case(resolve(target)) for _alias, target in imports(module, node)):
                providers.add(module)
        for node in ast.walk(tree):
            if isinstance(node, ast.ClassDef) and any(
                    isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)) and (member.name.startswith("test") or member.name == "runTest")
                    for member in node.body):
                providers.add(module)
    pending = list(strict)
    visited = set()
    while pending:
        module = pending.pop()
        if module in visited:
            continue
        visited.add(module)
        for node in trees[module].body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                for _alias, target in imports(module, node):
                    for provider in modules:
                        if target == provider or target.startswith(provider + "."):
                            if provider in providers:
                                strict.add(provider)
                            pending.append(provider)
    for name in classes:
        if is_test_case(name):
            for ancestor in mro(name):
                if ancestor in classes:
                    strict.add(ancestor.rsplit(".", 1)[0])

    def data_expression(module, node, before, local=None, visiting=()):
        if node is None or isinstance(node, ast.Constant):
            return True
        if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
            return all(data_expression(module, item, before, local, visiting) for item in node.elts)
        if isinstance(node, ast.Dict):
            return all(key is not None and data_expression(module, key, before, local, visiting)
                       and data_expression(module, value, before, local, visiting)
                       for key, value in zip(node.keys, node.values))
        if isinstance(node, ast.BinOp):
            return data_expression(module, node.left, before, local, visiting) and data_expression(module, node.right, before, local, visiting)
        if isinstance(node, ast.UnaryOp):
            return data_expression(module, node.operand, before, local, visiting)
        if isinstance(node, ast.Compare):
            return data_expression(module, node.left, before, local, visiting) and all(
                data_expression(module, value, before, local, visiting) for value in node.comparators)
        if isinstance(node, ast.Name):
            if node.id == "__file__":
                return True
            writes = (local or {}).get(node.id, events[module].get(node.id, []))
            prior = [item for item in writes if (item.lineno, item.col_offset) < before]
            if not prior or node.id in visiting:
                return False
            item = prior[-1]
            return isinstance(item, (ast.Assign, ast.AnnAssign)) and data_expression(
                module, item.value, (item.lineno, item.col_offset), local, (*visiting, node.id))
        if isinstance(node, ast.Attribute):
            try:
                attribute = resolve(module + "." + dotted(node))
            except ContractError:
                attribute = None
            if attribute == "sys.platform" and non_test_terminal(attribute) and stable_constructor(module, node, node):
                return True
            return node.attr in {"parent", "parents", "name", "stem", "suffix"} and path_expression(module, node.value, before, visiting)
        if isinstance(node, ast.Subscript):
            return path_expression(module, node.value, before, visiting) and data_expression(module, node.slice, before, local, visiting)
        if isinstance(node, ast.Call):
            if path_expression(module, node, before, visiting):
                return True
            try:
                function = resolve(module + "." + dotted(node.func))
            except ContractError:
                return False
            return non_test_terminal(function) and function in {"builtins." + name for name in ("bool", "int", "float", "complex", "str", "bytes",
                                                               "bytearray", "list", "tuple", "dict", "set", "frozenset")} and stable_constructor(module, node) and all(
                not isinstance(arg, ast.Starred) and data_expression(module, arg, before, local, visiting)
                for arg in node.args) and all(
                keyword.arg is not None and data_expression(module, keyword.value, before, local, visiting)
                for keyword in node.keywords)
        return False

    def stable_constructor(module, node, expression=None):
        root = dotted(expression if expression is not None else node.func).split(".")[0]
        writes = events[module].get(root, [])
        if not writes:
            return True
        targets = [resolve(target) for write in writes if isinstance(write, (ast.Import, ast.ImportFrom))
                   for alias, target in imports(module, write) if alias == root]
        return len(targets) == len(writes) and len(set(targets)) == 1 and (
            writes[0].lineno, writes[0].col_offset) < (node.lineno, node.col_offset)

    def path_expression(module, node, before, visiting=()):
        if isinstance(node, ast.Name):
            prior = [item for item in events[module].get(node.id, []) if (item.lineno, item.col_offset) < before]
            if node.id in visiting or not prior:
                return False
            item = prior[-1]
            return isinstance(item, (ast.Assign, ast.AnnAssign)) and path_expression(
                module, item.value, (item.lineno, item.col_offset), (*visiting, node.id))
        if isinstance(node, ast.Attribute):
            return node.attr in {"parent", "parents"} and path_expression(module, node.value, before, visiting)
        if isinstance(node, ast.Subscript):
            return path_expression(module, node.value, before, visiting) and data_expression(module, node.slice, before, visiting=visiting)
        if isinstance(node, ast.Call):
            if node.keywords or any(isinstance(arg, ast.Starred) for arg in node.args):
                return False
            try:
                function = resolve(module + "." + dotted(node.func))
            except ContractError:
                function = None
            constructor = function == "pathlib.Path" and non_test_terminal(function) and stable_constructor(module, node)
            method = isinstance(node.func, ast.Attribute) and node.func.attr in {"resolve", "with_name"} and path_expression(
                module, node.func.value, before, visiting)
            return (constructor or method) and all(data_expression(module, arg, before, visiting=visiting) for arg in node.args)
        return False

    def signature_expression(node, *, annotation=False):
        if node is None or isinstance(node, (ast.Constant, ast.Name)):
            return True
        if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
            return all(signature_expression(item, annotation=annotation) for item in node.elts)
        if isinstance(node, ast.Dict) and not annotation:
            return all(key is not None and signature_expression(key) and signature_expression(value)
                       for key, value in zip(node.keys, node.values))
        if isinstance(node, ast.Starred) and not annotation:
            return isinstance(node.value, (ast.Name, ast.Tuple, ast.List)) and signature_expression(node.value)
        if isinstance(node, ast.UnaryOp) and not annotation:
            return isinstance(node.operand, ast.Constant)
        if annotation and isinstance(node, ast.Attribute):
            return signature_expression(node.value, annotation=True)
        if annotation and isinstance(node, ast.Subscript):
            return signature_expression(node.value, annotation=True) and signature_expression(node.slice, annotation=True)
        if annotation and isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr):
            return signature_expression(node.left, annotation=True) and signature_expression(node.right, annotation=True)
        return False

    deferred_annotations = {module for module in strict if any(
        isinstance(item, ast.ImportFrom) and item.module == "__future__"
        and any(alias.name == "annotations" for alias in item.names) for item in trees[module].body)}

    def validate_annotation(module, annotation):
        if not signature_expression(annotation, annotation=True):
            fail(module, annotation, "annotation is outside the allowed declaration grammar")
        if annotation is not None and module not in deferred_annotations:
            for child in ast.walk(annotation):
                if isinstance(child, ast.BinOp):
                    fail(module, child, "type unions require deferred annotations")
                if isinstance(child, (ast.Attribute, ast.Subscript)):
                    expression = child.value if isinstance(child, ast.Subscript) else child
                    try:
                        target = resolve(module + "." + dotted(expression))
                    except ContractError:
                        target = None
                    if target is None or not non_test_terminal(target) or not stable_constructor(module, child, expression):
                        fail(module, child, "runtime type lookup requires an unshadowed standard-library type or deferred annotations")

    def function_definition(module, node, defined):
        if node.name in {"load_tests", "__getattr__", "__dir__", "__init_subclass__", "__getattribute__", "__new__", "__class_getitem__"}:
            fail(module, node, "discovery hook is outside the allowed grammar")
        for default in node.args.defaults + node.args.kw_defaults:
            if not signature_expression(default):
                fail(module, default, "definition default is outside the allowed signature grammar")
        arguments = node.args.posonlyargs + node.args.args + node.args.kwonlyargs
        arguments += [arg for arg in (node.args.vararg, node.args.kwarg) if arg is not None]
        for annotation in [arg.annotation for arg in arguments] + [node.returns]:
            validate_annotation(module, annotation)
        for decorator in node.decorator_list:
            expression = decorator.func if isinstance(decorator, ast.Call) else decorator
            try:
                root = dotted(expression).split(".")[0]
            except ContractError:
                root = None
            if root in defined:
                fail(module, decorator, "decorator binding cannot be shadowed")
            if isinstance(decorator, ast.Name) and decorator.id in {"classmethod", "staticmethod", "property"} and decorator.id not in events[module]:
                if decorator.id == "property" and (node.name.startswith("test") or node.name == "runTest"):
                    fail(module, decorator, "test methods must remain callable")
                continue
            try:
                target = resolve(module + "." + dotted(expression))
            except ContractError:
                target = None
            if target == "unittest.expectedFailure" and not isinstance(decorator, ast.Call) and stable_constructor(module, decorator, expression):
                continue
            if isinstance(decorator, ast.Call) and target in {"unittest.skip", "unittest.skipIf", "unittest.skipUnless"} and stable_constructor(module, decorator) and not decorator.keywords and all(
                    data_expression(module, arg, (node.lineno, node.col_offset)) for arg in decorator.args):
                continue
            fail(module, decorator, "function decorator is outside the allowed grammar")

    def validate_module(module):
        protected = {node.name for node in trees[module].body if isinstance(node, ast.ClassDef)}
        for node in trees[module].body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias, target in imports(module, node):
                    if resolve(target) in classes or resolve(target) in terminals:
                        protected.add(alias)
            if isinstance(node, ast.ClassDef):
                for base in node.bases:
                    if not isinstance(base, (ast.Name, ast.Attribute)):
                        fail(module, base, "base must be a name or attribute in the allowed grammar")
                    try:
                        spelling = dotted(base)
                    except ContractError:
                        fail(module, base, "base must be a statically resolved name or attribute")
                    root = spelling.split(".")[0]
                    protected.add(root)
                    writes = events[module].get(root, [])
                    if writes and (len(writes) != 1 or (writes[0].lineno, writes[0].col_offset) >= (node.lineno, node.col_offset)):
                        fail(module, base, "base binding must occur once before class definition")
                    target = resolve(module + "." + spelling)
                    if target not in classes and target not in terminals and not non_test_terminal(target):
                        fail(module, base, "unresolved Python test base: " + target)

        def statements(body, *, class_body=False):
            local = {}
            for node in body:
                if isinstance(node, (ast.Assign, ast.AnnAssign)):
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    for target in targets:
                        if isinstance(target, ast.Name):
                            local.setdefault(target.id, []).append(node)
            defined = set()
            for node in body:
                if isinstance(node, (ast.Import, ast.ImportFrom)) and not class_body:
                    if isinstance(node, ast.ImportFrom) and any(alias.name == "*" for alias in node.names):
                        fail(module, node, "star import is outside the allowed grammar")
                    for alias, _target in imports(module, node):
                        if alias in protected and alias in defined:
                            fail(module, node, "class or base binding cannot be rebound")
                        defined.add(alias)
                elif isinstance(node, ast.ClassDef) and not class_body:
                    if node.decorator_list or node.keywords:
                        fail(module, node, "class decorators and metaclasses are outside the allowed grammar")
                    if node.name in defined:
                        fail(module, node, "class binding cannot be rebound")
                    defined.add(node.name)
                    statements(node.body, class_body=True)
                elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    function_definition(module, node, defined if class_body else set())
                    if node.name in defined and (node.name in protected or node.name.startswith("test") or node.name == "runTest"):
                        fail(module, node, "class, base or test member cannot be rebound")
                    defined.add(node.name)
                elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                    if isinstance(node, ast.AnnAssign):
                        validate_annotation(module, node.annotation)
                    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                    if len(targets) != 1 or not isinstance(targets[0], ast.Name):
                        fail(module, node, "only a single data name can be assigned")
                    target = targets[0].id
                    if target.startswith("test") or target in protected or target in {"runTest", "load_tests", "__getattr__", "__dir__"}:
                        fail(module, node, "assignment cannot bind a class, base or test member")
                    if class_body and node.value is not None and any(isinstance(child, ast.Call) for child in ast.walk(node.value)):
                        fail(module, node, "class data assignments must not call functions")
                    if not data_expression(module, node.value, (node.lineno, node.col_offset), local):
                        fail(module, node, "assignment requires a supported data expression")
                    defined.add(target)
                elif isinstance(node, ast.Pass) or (isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant)
                                                    and isinstance(node.value.value, str)):
                    continue
                elif not class_body and isinstance(node, ast.If) and ast.dump(node.test) == ast.dump(
                        ast.parse('__name__ == "__main__"', mode="eval").body) and not node.orelse and len(node.body) == 1:
                    call = node.body[0]
                    try:
                        target = resolve(module + "." + dotted(call.value.func)) if isinstance(call, ast.Expr) and isinstance(call.value, ast.Call) else None
                    except ContractError:
                        target = None
                    if not (isinstance(call, ast.Expr) and isinstance(call.value, ast.Call) and not call.value.args
                            and not call.value.keywords and target == "unittest.main"):
                        fail(module, node, "only the exact unittest.main guard is allowed")
                else:
                    fail(module, node, type(node).__name__ + " is outside the allowed declaration grammar")
        statements(trees[module].body)

    for module in sorted(strict):
        validate_module(module)

    identities, seen_classes = [], set()
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
                if ancestor == "doctest.DocTestCase":
                    methods.setdefault("runTest", True)
                if ancestor in classes:
                    for member in classes[ancestor].body:
                        if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
                            methods.setdefault(member.name, True)
            selected = [method for method in methods if method.startswith("test")]
            if not selected and "runTest" in methods:
                selected = ["runTest"]
            identities.extend(test_identity("python", name + "." + method) for method in selected)
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
