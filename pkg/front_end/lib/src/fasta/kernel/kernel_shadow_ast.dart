// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This file declares a "shadow hierarchy" of concrete classes which extend
/// the kernel class hierarchy, adding methods and fields needed by the
/// BodyBuilder.
///
/// Instances of these classes may be created using the factory methods in
/// `ast_factory.dart`.
///
/// Note that these classes represent the Dart language prior to desugaring.
/// When a single Dart construct desugars to a tree containing multiple kernel
/// AST nodes, the shadow class extends the kernel object at the top of the
/// desugared tree.
///
/// This means that in some cases multiple shadow classes may extend the same
/// kernel class, because multiple constructs in Dart may desugar to a tree
/// with the same kind of root node.

import 'dart:core' hide MapEntry;

import 'package:kernel/ast.dart' hide Variance;

import 'package:kernel/type_algebra.dart' show Substitution;

import 'package:kernel/type_environment.dart';

import 'package:kernel/clone.dart';

import '../../base/instrumentation.dart'
    show
        InstrumentationValueForMember,
        InstrumentationValueForType,
        InstrumentationValueForTypeArgs;

import '../builder/library_builder.dart';

import '../fasta_codes.dart'
    show
        messageCantDisambiguateAmbiguousInformation,
        messageCantDisambiguateNotEnoughInformation,
        messageNonNullAwareSpreadIsNull,
        messageSwitchExpressionNotAssignableCause,
        noLength,
        templateCantInferTypeDueToCircularity,
        templateForInLoopElementTypeNotAssignable,
        templateForInLoopTypeNotIterable,
        templateIntegerLiteralIsOutOfRange,
        templateSpreadElementTypeMismatch,
        templateSpreadMapEntryElementKeyTypeMismatch,
        templateSpreadMapEntryElementValueTypeMismatch,
        templateSpreadMapEntryTypeMismatch,
        templateSpreadTypeMismatch,
        templateSwitchExpressionNotAssignable,
        templateUndefinedSetter,
        templateWebLiteralCannotBeRepresentedExactly;

import '../names.dart';

import '../problems.dart' show unhandled, unsupported;

import '../source/source_class_builder.dart' show SourceClassBuilder;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import '../type_inference/type_inference_engine.dart';
import '../type_inference/type_inferrer.dart';

import '../type_inference/type_promotion.dart'
    show TypePromoter, TypePromoterImpl, TypePromotionFact, TypePromotionScope;

import '../type_inference/type_schema.dart' show UnknownType;

import '../type_inference/type_schema_elimination.dart' show greatestClosure;

import '../type_inference/type_schema_environment.dart'
    show TypeSchemaEnvironment;

import 'body_builder.dart' show combineStatements;

import 'collections.dart'
    show
        ForElement,
        ForInElement,
        ForInMapEntry,
        ForMapEntry,
        IfElement,
        IfMapEntry,
        SpreadElement,
        SpreadMapEntry,
        convertToElement;

import 'implicit_type_argument.dart' show ImplicitTypeArgument;

part "inference_visitor.dart";

/// Computes the return type of a (possibly factory) constructor.
InterfaceType computeConstructorReturnType(Member constructor) {
  if (constructor is Constructor) {
    return constructor.enclosingClass.thisType;
  } else {
    return constructor.function.returnType;
  }
}

int getExtensionTypeParameterCount(Arguments arguments) {
  if (arguments is ArgumentsImpl) {
    return arguments._extensionTypeParameterCount;
  } else {
    // TODO(johnniwinther): Remove this path or assert why it is accepted.
    return 0;
  }
}

int getExtensionTypeArgumentCount(Arguments arguments) {
  if (arguments is ArgumentsImpl) {
    return arguments._explicitExtensionTypeArgumentCount;
  } else {
    // TODO(johnniwinther): Remove this path or assert why it is accepted.
    return 0;
  }
}

List<DartType> getExplicitExtensionTypeArguments(Arguments arguments) {
  if (arguments is ArgumentsImpl) {
    if (arguments._explicitExtensionTypeArgumentCount == 0) {
      return null;
    } else {
      return arguments.types
          .take(arguments._explicitExtensionTypeArgumentCount)
          .toList();
    }
  } else {
    // TODO(johnniwinther): Remove this path or assert why it is accepted.
    return null;
  }
}

/// Information about explicit/implicit type arguments used for error
/// reporting.
abstract class TypeArgumentsInfo {
  const TypeArgumentsInfo();

  /// Returns `true` if the [index]th type argument was inferred.
  bool isInferred(int index);

  /// Returns the offset to use when reporting an error on the [index]th type
  /// arguments, using [offset] as the default offset.
  int getOffsetForIndex(int index, int offset) => offset;
}

class AllInferredTypeArgumentsInfo extends TypeArgumentsInfo {
  const AllInferredTypeArgumentsInfo();

  bool isInferred(int index) => true;
}

class NoneInferredTypeArgumentsInfo extends TypeArgumentsInfo {
  const NoneInferredTypeArgumentsInfo();

  bool isInferred(int index) => false;
}

class ExtensionMethodTypeArgumentsInfo implements TypeArgumentsInfo {
  final ArgumentsImpl arguments;

  ExtensionMethodTypeArgumentsInfo(this.arguments);

  bool isInferred(int index) {
    if (index < arguments._extensionTypeParameterCount) {
      // The index refers to a type argument for a type parameter declared on
      // the extension. Check whether we have enough explicit extension type
      // arguments.
      return index >= arguments._explicitExtensionTypeArgumentCount;
    }
    // The index refers to a type argument for a type parameter declared on
    // the method. Check whether we have enough explicit regular type arguments.
    return index - arguments._extensionTypeParameterCount >=
        arguments._explicitTypeArgumentCount;
  }

  int getOffsetForIndex(int index, int offset) {
    if (index < arguments._extensionTypeParameterCount) {
      return arguments._extensionTypeArgumentOffset ?? offset;
    }
    return offset;
  }
}

TypeArgumentsInfo getTypeArgumentsInfo(Arguments arguments) {
  if (arguments is ArgumentsImpl) {
    if (arguments._extensionTypeParameterCount == 0) {
      return arguments._explicitTypeArgumentCount == 0
          ? const AllInferredTypeArgumentsInfo()
          : const NoneInferredTypeArgumentsInfo();
    } else {
      return new ExtensionMethodTypeArgumentsInfo(arguments);
    }
  } else {
    // This code path should only be taken in situations where there are no
    // type arguments at all, e.g. calling a user-definable operator.
    assert(arguments.types.isEmpty);
    return const NoneInferredTypeArgumentsInfo();
  }
}

List<DartType> getExplicitTypeArguments(Arguments arguments) {
  if (arguments is ArgumentsImpl) {
    if (arguments._explicitTypeArgumentCount == 0) {
      return null;
    } else if (arguments._extensionTypeParameterCount == 0) {
      return arguments.types;
    } else {
      return arguments.types
          .skip(arguments._extensionTypeParameterCount)
          .toList();
    }
  } else {
    // This code path should only be taken in situations where there are no
    // type arguments at all, e.g. calling a user-definable operator.
    assert(arguments.types.isEmpty);
    return null;
  }
}

/// Information associated with a class during type inference.
class ClassInferenceInfo {
  /// The builder associated with this class.
  final SourceClassBuilder builder;

  /// The visitor for determining if a given type makes covariant use of one of
  /// the class's generic parameters, and therefore requires covariant checks.
  IncludesTypeParametersNonCovariantly needsCheckVisitor;

  /// Getters and methods in the class's API.  May include forwarding nodes.
  final gettersAndMethods = <Member>[];

  /// Setters in the class's API.  May include forwarding nodes.
  final setters = <Member>[];

  ClassInferenceInfo(this.builder);
}

enum InternalExpressionKind {
  Binary,
  Cascade,
  CompoundExtensionIndexSet,
  CompoundExtensionSet,
  CompoundIndexSet,
  CompoundPropertySet,
  CompoundSuperIndexSet,
  DeferredCheck,
  Equals,
  ExtensionIndexSet,
  ExtensionTearOff,
  ExtensionSet,
  IfNull,
  IfNullExtensionIndexSet,
  IfNullIndexSet,
  IfNullPropertySet,
  IfNullSet,
  IfNullSuperIndexSet,
  IndexSet,
  LoadLibraryTearOff,
  LocalPostIncDec,
  NullAwareCompoundSet,
  NullAwareExtension,
  NullAwareIfNullSet,
  NullAwareMethodInvocation,
  NullAwarePropertyGet,
  NullAwarePropertySet,
  Parenthesized,
  PropertyPostIncDec,
  StaticPostIncDec,
  SuperIndexSet,
  SuperPostIncDec,
  Unary,
}

/// Common base class for internal expressions.
abstract class InternalExpression extends Expression {
  InternalExpressionKind get kind;

  @override
  R accept<R>(ExpressionVisitor<R> visitor) => visitor.defaultExpression(this);

  @override
  R accept1<R, A>(ExpressionVisitor1<R, A> visitor, A arg) =>
      visitor.defaultExpression(this, arg);

  @override
  DartType getStaticType(types) =>
      unsupported("${runtimeType}.getStaticType", -1, null);
}

/// Front end specific implementation of [Argument].
class ArgumentsImpl extends Arguments {
  // TODO(johnniwinther): Move this to the static invocation instead.
  final int _extensionTypeParameterCount;

  final int _explicitExtensionTypeArgumentCount;

  final int _extensionTypeArgumentOffset;

  int _explicitTypeArgumentCount;

  ArgumentsImpl(List<Expression> positional,
      {List<DartType> types, List<NamedExpression> named})
      : _explicitTypeArgumentCount = types?.length ?? 0,
        _extensionTypeParameterCount = 0,
        _explicitExtensionTypeArgumentCount = 0,
        // The offset is unused in this case.
        _extensionTypeArgumentOffset = null,
        super(positional, types: types, named: named);

  ArgumentsImpl.forExtensionMethod(int extensionTypeParameterCount,
      int typeParameterCount, Expression receiver,
      {List<DartType> extensionTypeArguments = const <DartType>[],
      int extensionTypeArgumentOffset,
      List<DartType> typeArguments = const <DartType>[],
      List<Expression> positionalArguments = const <Expression>[],
      List<NamedExpression> namedArguments = const <NamedExpression>[]})
      : _extensionTypeParameterCount = extensionTypeParameterCount,
        _explicitExtensionTypeArgumentCount = extensionTypeArguments.length,
        _explicitTypeArgumentCount = typeArguments.length,
        _extensionTypeArgumentOffset = extensionTypeArgumentOffset,
        assert(
            extensionTypeArguments.isEmpty ||
                extensionTypeArguments.length == extensionTypeParameterCount,
            "Extension type arguments must be empty or complete."),
        super(<Expression>[receiver]..addAll(positionalArguments),
            named: namedArguments,
            types: <DartType>[]
              ..addAll(_normalizeTypeArguments(
                  extensionTypeParameterCount, extensionTypeArguments))
              ..addAll(
                  _normalizeTypeArguments(typeParameterCount, typeArguments)));

  static List<DartType> _normalizeTypeArguments(
      int length, List<DartType> arguments) {
    if (arguments.isEmpty && length > 0) {
      return new List<DartType>.filled(length, const UnknownType());
    }
    return arguments;
  }

  static void setNonInferrableArgumentTypes(
      ArgumentsImpl arguments, List<DartType> types) {
    arguments.types.clear();
    arguments.types.addAll(types);
    arguments._explicitTypeArgumentCount = types.length;
  }

  static void removeNonInferrableArgumentTypes(ArgumentsImpl arguments) {
    arguments.types.clear();
    arguments._explicitTypeArgumentCount = 0;
  }
}

/// Internal expression representing a cascade expression.
///
/// A cascade expression of the form `a..b()..c()` is represented as the kernel
/// expression:
///
///     let v = a in
///         let _ = v.b() in
///             let _ = v.c() in
///                 v
///
/// In the documentation that follows, `v` is referred to as the "cascade
/// variable"--this is the variable that remembers the value of the expression
/// preceding the first `..` while the cascades are being evaluated.
class Cascade extends InternalExpression {
  /// The temporary variable holding the cascade receiver expression in its
  /// initializer;
  VariableDeclaration variable;

  /// The expressions performed on [variable].
  final List<Expression> expressions = <Expression>[];

  /// Creates a [Cascade] using [variable] as the cascade
  /// variable.  Caller is responsible for ensuring that [variable]'s
  /// initializer is the expression preceding the first `..` of the cascade
  /// expression.
  Cascade(this.variable) {
    variable?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.Cascade;

  /// Adds [expression] to the list of [expressions] performed on [variable].
  void addCascadeExpression(Expression expression) {
    expressions.add(expression);
    expression.parent = this;
  }

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    visitList(expressions, v);
  }

  @override
  void transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    transformList(expressions, v, this);
  }
}

/// Internal expression representing a deferred check.
// TODO(johnniwinther): Change the representation to be direct and perform
// the [Let] encoding in the replacement.
class DeferredCheck extends InternalExpression {
  VariableDeclaration variable;
  Expression expression;

  DeferredCheck(this.variable, this.expression) {
    variable?.parent = this;
    expression?.parent = this;
  }

  InternalExpressionKind get kind => InternalExpressionKind.DeferredCheck;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    expression?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (expression != null) {
      expression = expression.accept<TreeNode>(v);
      expression?.parent = this;
    }
  }
}

/// Common base class for shadow objects representing expressions in kernel
/// form.
abstract class ExpressionJudgment extends Expression {
  /// Calls back to [inferrer] to perform type inference for whatever concrete
  /// type of [Expression] this is.
  ExpressionInferenceResult acceptInference(
      InferenceVisitor visitor, DartType typeContext);
}

/// Shadow object for [StaticInvocation] when the procedure being invoked is a
/// factory constructor.
class FactoryConstructorInvocationJudgment extends StaticInvocation
    implements ExpressionJudgment {
  bool hasBeenInferred = false;

  FactoryConstructorInvocationJudgment(
      Procedure target, ArgumentsImpl arguments,
      {bool isConst: false})
      : super(target, arguments, isConst: isConst);

  @override
  ExpressionInferenceResult acceptInference(
      InferenceVisitor visitor, DartType typeContext) {
    return visitor.visitFactoryConstructorInvocationJudgment(this, typeContext);
  }
}

/// Front end specific implementation of [FunctionDeclaration].
class FunctionDeclarationImpl extends FunctionDeclaration {
  bool _hasImplicitReturnType = false;

  FunctionDeclarationImpl(
      VariableDeclarationImpl variable, FunctionNode function)
      : super(variable, function);

  static void setHasImplicitReturnType(
      FunctionDeclarationImpl declaration, bool hasImplicitReturnType) {
    declaration._hasImplicitReturnType = hasImplicitReturnType;
  }
}

/// Concrete shadow object representing a super initializer in kernel form.
class InvalidSuperInitializerJudgment extends LocalInitializer
    implements InitializerJudgment {
  final Constructor target;
  final ArgumentsImpl argumentsJudgment;

  InvalidSuperInitializerJudgment(
      this.target, this.argumentsJudgment, VariableDeclaration variable)
      : super(variable);

  @override
  void acceptInference(InferenceVisitor visitor) {
    return visitor.visitInvalidSuperInitializerJudgment(this);
  }
}

/// Internal expression representing an if-null expression.
///
/// An if-null expression of the form `a ?? b` is encoded as:
///
///     let v = a in v == null ? b : v
///
class IfNullExpression extends InternalExpression {
  Expression left;
  Expression right;

  IfNullExpression(this.left, this.right) {
    left?.parent = this;
    right?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IfNull;

  @override
  void visitChildren(Visitor<dynamic> v) {
    left?.accept(v);
    right?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (left != null) {
      left = left.accept<TreeNode>(v);
      left?.parent = this;
    }
    if (right != null) {
      right = right.accept<TreeNode>(v);
      right?.parent = this;
    }
  }
}

/// Common base class for shadow objects representing initializers in kernel
/// form.
abstract class InitializerJudgment implements Initializer {
  /// Performs type inference for whatever concrete type of
  /// [InitializerJudgment] this is.
  void acceptInference(InferenceVisitor visitor);
}

Expression checkWebIntLiteralsErrorIfUnexact(
    TypeInferrerImpl inferrer, int value, String literal, int charOffset) {
  if (value >= 0 && value <= (1 << 53)) return null;
  if (inferrer.isTopLevel) return null;
  if (!inferrer.library.loader.target.backendTarget
      .errorOnUnexactWebIntLiterals) return null;
  BigInt asInt = new BigInt.from(value).toUnsigned(64);
  BigInt asDouble = new BigInt.from(asInt.toDouble());
  if (asInt == asDouble) return null;
  String text = literal ?? value.toString();
  String nearest = text.startsWith('0x') || text.startsWith('0X')
      ? '0x${asDouble.toRadixString(16)}'
      : asDouble.toString();
  int length = literal?.length ?? noLength;
  return inferrer.helper.buildProblem(
      templateWebLiteralCannotBeRepresentedExactly.withArguments(text, nearest),
      charOffset,
      length);
}

/// Concrete shadow object representing an integer literal in kernel form.
class IntJudgment extends IntLiteral implements ExpressionJudgment {
  final String literal;

  IntJudgment(int value, this.literal) : super(value);

  double asDouble({bool negated: false}) {
    if (value == 0 && negated) return -0.0;
    BigInt intValue = new BigInt.from(negated ? -value : value);
    double doubleValue = intValue.toDouble();
    return intValue == new BigInt.from(doubleValue) ? doubleValue : null;
  }

  @override
  ExpressionInferenceResult acceptInference(
      InferenceVisitor visitor, DartType typeContext) {
    return visitor.visitIntJudgment(this, typeContext);
  }
}

class ShadowLargeIntLiteral extends IntLiteral implements ExpressionJudgment {
  final String literal;
  final int fileOffset;
  bool isParenthesized = false;

  ShadowLargeIntLiteral(this.literal, this.fileOffset) : super(0);

  double asDouble({bool negated: false}) {
    BigInt intValue = BigInt.tryParse(negated ? '-${literal}' : literal);
    if (intValue == null) return null;
    double doubleValue = intValue.toDouble();
    return !doubleValue.isNaN &&
            !doubleValue.isInfinite &&
            intValue == new BigInt.from(doubleValue)
        ? doubleValue
        : null;
  }

  int asInt64({bool negated: false}) {
    return int.tryParse(negated ? '-${literal}' : literal);
  }

  @override
  ExpressionInferenceResult acceptInference(
      InferenceVisitor visitor, DartType typeContext) {
    return visitor.visitShadowLargeIntLiteral(this, typeContext);
  }
}

/// Concrete shadow object representing an invalid initializer in kernel form.
class ShadowInvalidInitializer extends LocalInitializer
    implements InitializerJudgment {
  ShadowInvalidInitializer(VariableDeclaration variable) : super(variable);

  @override
  void acceptInference(InferenceVisitor visitor) {
    return visitor.visitShadowInvalidInitializer(this);
  }
}

/// Concrete shadow object representing an invalid initializer in kernel form.
class ShadowInvalidFieldInitializer extends LocalInitializer
    implements InitializerJudgment {
  Field field;
  Expression value;

  ShadowInvalidFieldInitializer(
      this.field, this.value, VariableDeclaration variable)
      : super(variable) {
    value?.parent = this;
  }

  @override
  void acceptInference(InferenceVisitor visitor) {
    return visitor.visitShadowInvalidFieldInitializer(this);
  }
}

/// Front end specific implementation of [MethodInvocation].
class MethodInvocationImpl extends MethodInvocation {
  /// Indicates whether this method invocation is a call to a `call` method
  /// resulting from the invocation of a function expression.
  final bool isImplicitCall;

  MethodInvocationImpl(Expression receiver, Name name, ArgumentsImpl arguments,
      {this.isImplicitCall: false, Member interfaceTarget})
      : super(receiver, name, arguments, interfaceTarget);
}

/// Concrete shadow object representing a named function expression.
///
/// Named function expressions are not legal in Dart, but they are accepted by
/// the parser and BodyBuilder for error recovery purposes.
///
/// A named function expression of the form `f() { ... }` is represented as the
/// kernel expression:
///
///     let f = () { ... } in f
class NamedFunctionExpressionJudgment extends Let
    implements ExpressionJudgment {
  NamedFunctionExpressionJudgment(VariableDeclarationImpl variable)
      : super(variable, new VariableGet(variable));

  @override
  ExpressionInferenceResult acceptInference(
      InferenceVisitor visitor, DartType typeContext) {
    return visitor.visitNamedFunctionExpressionJudgment(this, typeContext);
  }
}

/// Internal expression representing a null-aware method invocation.
///
/// A null-aware method invocation of the form `a?.b(...)` is encoded as:
///
///     let v = a in v == null ? null : v.b(...)
///
class NullAwareMethodInvocation extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  VariableDeclaration variable;

  /// The expression that invokes the method on [variable].
  Expression invocation;

  NullAwareMethodInvocation(this.variable, this.invocation) {
    variable?.parent = this;
    invocation?.parent = this;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.NullAwareMethodInvocation;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    invocation?.accept(v);
  }

  @override
  transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (invocation != null) {
      invocation = invocation.accept<TreeNode>(v);
      invocation?.parent = this;
    }
  }
}

/// Internal expression representing a null-aware read from a property.
///
/// A null-aware property get of the form `a?.b` is encoded as:
///
///     let v = a in v == null ? null : v.b
///
class NullAwarePropertyGet extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  VariableDeclaration variable;

  /// The expression that reads the property from [variable].
  Expression read;

  NullAwarePropertyGet(this.variable, this.read) {
    variable?.parent = this;
    read?.parent = this;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.NullAwarePropertyGet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    read?.accept(v);
  }

  @override
  transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
  }
}

/// Internal expression representing a null-aware read from a property.
///
/// A null-aware property get of the form `a?.b = c` is encoded as:
///
///     let v = a in v == null ? null : v.b = c
///
class NullAwarePropertySet extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  VariableDeclaration variable;

  /// The expression that writes the value to the property in [variable].
  Expression write;

  NullAwarePropertySet(this.variable, this.write) {
    variable?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.NullAwarePropertySet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    write?.accept(v);
  }

  @override
  transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Front end specific implementation of [ReturnStatement].
class ReturnStatementImpl extends ReturnStatement {
  final bool isArrow;

  ReturnStatementImpl(this.isArrow, [Expression expression])
      : super(expression);
}

/// Concrete implementation of [TypePromoter] specialized to work with kernel
/// objects.
class ShadowTypePromoter extends TypePromoterImpl {
  ShadowTypePromoter.private(TypeSchemaEnvironment typeSchemaEnvironment)
      : super.private(typeSchemaEnvironment);

  @override
  int getVariableFunctionNestingLevel(VariableDeclaration variable) {
    if (variable is VariableDeclarationImpl) {
      return variable._functionNestingLevel;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
      return 0;
    }
  }

  @override
  bool isPromotionCandidate(VariableDeclaration variable) {
    assert(variable is VariableDeclarationImpl);
    VariableDeclarationImpl kernelVariableDeclaration = variable;
    return !kernelVariableDeclaration._isLocalFunction;
  }

  @override
  bool sameExpressions(Expression a, Expression b) {
    return identical(a, b);
  }

  @override
  void setVariableMutatedAnywhere(VariableDeclaration variable) {
    if (variable is VariableDeclarationImpl) {
      variable._mutatedAnywhere = true;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
    }
  }

  @override
  void setVariableMutatedInClosure(VariableDeclaration variable) {
    if (variable is VariableDeclarationImpl) {
      variable._mutatedInClosure = true;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
    }
  }

  @override
  bool wasVariableMutatedAnywhere(VariableDeclaration variable) {
    if (variable is VariableDeclarationImpl) {
      return variable._mutatedAnywhere;
    } else {
      // Hack to deal with the fact that BodyBuilder still creates raw
      // VariableDeclaration objects sometimes.
      // TODO(paulberry): get rid of this once the type parameter is
      // KernelVariableDeclaration.
      return true;
    }
  }
}

/// Front end specific implementation of [VariableDeclaration].
class VariableDeclarationImpl extends VariableDeclaration {
  final bool forSyntheticToken;

  final bool _implicitlyTyped;

  // TODO(ahe): Remove this field. We can get rid of it by recording closure
  // mutation in [BodyBuilder].
  final int _functionNestingLevel;

  // TODO(ahe): Remove this field. It's only used locally when compiling a
  // method, and this can thus be tracked in a [Set] (actually, tracking this
  // information in a [List] is probably even faster as the average size will
  // be close to zero).
  bool _mutatedInClosure = false;

  // TODO(ahe): Investigate if this can be removed.
  bool _mutatedAnywhere = false;

  // TODO(ahe): Investigate if this can be removed.
  final bool _isLocalFunction;

  VariableDeclarationImpl(String name, this._functionNestingLevel,
      {this.forSyntheticToken: false,
      Expression initializer,
      DartType type,
      bool isFinal: false,
      bool isConst: false,
      bool isFieldFormal: false,
      bool isCovariant: false,
      bool isLocalFunction: false,
      bool isLate: false,
      bool isRequired: false})
      : _implicitlyTyped = type == null,
        _isLocalFunction = isLocalFunction,
        super(name,
            initializer: initializer,
            type: type ?? const DynamicType(),
            isFinal: isFinal,
            isConst: isConst,
            isFieldFormal: isFieldFormal,
            isCovariant: isCovariant,
            isLate: isLate,
            isRequired: isRequired);

  VariableDeclarationImpl.forEffect(Expression initializer)
      : forSyntheticToken = false,
        _functionNestingLevel = 0,
        _implicitlyTyped = false,
        _isLocalFunction = false,
        super.forValue(initializer);

  VariableDeclarationImpl.forValue(Expression initializer)
      : forSyntheticToken = false,
        _functionNestingLevel = 0,
        _implicitlyTyped = true,
        _isLocalFunction = false,
        super.forValue(initializer);

  /// Determine whether the given [VariableDeclarationImpl] had an implicit
  /// type.
  ///
  /// This is static to avoid introducing a method that would be visible to
  /// the kernel.
  static bool isImplicitlyTyped(VariableDeclarationImpl variable) =>
      variable._implicitlyTyped;

  /// Determines whether the given [VariableDeclarationImpl] represents a
  /// local function.
  ///
  /// This is static to avoid introducing a method that would be visible to the
  /// kernel.
  static bool isLocalFunction(VariableDeclarationImpl variable) =>
      variable._isLocalFunction;
}

/// Front end specific implementation of [VariableGet].
class VariableGetImpl extends VariableGet {
  final TypePromotionFact _fact;

  final TypePromotionScope _scope;

  VariableGetImpl(VariableDeclaration variable, this._fact, this._scope)
      : super(variable);
}

/// Front end specific implementation of [LoadLibrary].
class LoadLibraryImpl extends LoadLibrary {
  final Arguments arguments;

  LoadLibraryImpl(LibraryDependency import, this.arguments) : super(import);
}

/// Internal expression representing a tear-off of a `loadLibrary` function.
class LoadLibraryTearOff extends InternalExpression {
  LibraryDependency import;
  Procedure target;

  LoadLibraryTearOff(this.import, this.target);

  @override
  InternalExpressionKind get kind => InternalExpressionKind.LoadLibraryTearOff;

  @override
  void visitChildren(Visitor<dynamic> v) {
    import?.accept(v);
    target?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (import != null) {
      import = import.accept<TreeNode>(v);
    }
    if (target != null) {
      target = target.accept<TreeNode>(v);
    }
  }
}

/// Internal expression representing an if-null property set.
///
/// An if-null property set of the form `o.a ??= b` is, if used for value,
/// encoded as the expression:
///
///     let v1 = o in let v2 = v1.a in v2 == null ? v1.a = b : v2
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = o in v1.a == null ? v1.a = b : null
///
class IfNullPropertySet extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  VariableDeclaration variable;

  /// The expression that reads the property from [variable].
  Expression read;

  /// The expression that writes the value to the property on [variable].
  Expression write;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  IfNullPropertySet(this.variable, this.read, this.write, {this.forEffect})
      : assert(forEffect != null) {
    variable?.parent = this;
    read?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IfNullPropertySet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an if-null assignment.
///
/// An if-null assignment of the form `a ??= b` is, if used for value,
/// encoded as the expression:
///
///     let v1 = a in v1 == null ? a = b : v1
///
/// and, if used for effect, encoded as the expression:
///
///     a == null ? a = b : null
///
class IfNullSet extends InternalExpression {
  /// The expression that reads the property from [variable].
  Expression read;

  /// The expression that writes the value to the property on [variable].
  Expression write;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  IfNullSet(this.read, this.write, {this.forEffect})
      : assert(forEffect != null) {
    read?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IfNullSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an compound extension assignment.
///
/// An compound extension assignment of the form
///
///     Extension(receiver).propertyName += rhs
///
/// is, if used for value, encoded as the expression:
///
///     let receiverVariable = receiver in
///       let valueVariable =
///           Extension|get#propertyName(receiverVariable) + rhs) in
///         let writeVariable =
///             Extension|set#propertyName(receiverVariable, valueVariable) in
///           valueVariable
///
/// and if used for effect as:
///
///     let receiverVariable = receiver in
///         Extension|set#propertyName(receiverVariable,
///           Extension|get#propertyName(receiverVariable) + rhs)
///
/// If [readOnlyReceiver] is `true` the [receiverVariable] is not created
/// and the [receiver] is used directly.
class CompoundExtensionSet extends InternalExpression {
  /// The extension in which the [setter] is declared.
  final Extension extension;

  /// The explicit type arguments for the type parameters declared in
  /// [extension].
  final List<DartType> explicitTypeArguments;

  /// The receiver used for the read/write operations.
  Expression receiver;

  /// The name of the property accessed by the read/write operations.
  final Name propertyName;

  /// The member used for the read operation.
  final Member getter;

  /// The binary operation performed on the getter result and [rhs].
  final Name binaryName;

  /// The right-hand side of the binary operation.
  Expression rhs;

  /// The member used for the write operation.
  final Member setter;

  /// If `true`, the receiver is read-only and therefore doesn't need a
  /// temporary variable for its value.
  final bool readOnlyReceiver;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// The file offset for the read operation.
  final int readOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// The file offset for the write operation.
  final int writeOffset;

  CompoundExtensionSet(
      this.extension,
      this.explicitTypeArguments,
      this.receiver,
      this.propertyName,
      this.getter,
      this.binaryName,
      this.rhs,
      this.setter,
      {this.readOnlyReceiver,
      this.forEffect,
      this.readOffset,
      this.binaryOffset,
      this.writeOffset})
      : assert(readOnlyReceiver != null),
        assert(forEffect != null),
        assert(readOffset != null),
        assert(binaryOffset != null),
        assert(writeOffset != null) {
    receiver?.parent = this;
    rhs?.parent = this;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.CompoundExtensionSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing an compound property assignment.
///
/// An compound property assignment of the form
///
///     receiver.propertyName += rhs
///
/// is encoded as the expression:
///
///     let receiverVariable = receiver in
///       receiverVariable.propertyName = receiverVariable.propertyName + rhs
///
class CompoundPropertySet extends InternalExpression {
  /// The receiver used for the read/write operations.
  Expression receiver;

  /// The name of the property accessed by the read/write operations.
  final Name propertyName;

  /// The binary operation performed on the getter result and [rhs].
  final Name binaryName;

  /// The right-hand side of the binary operation.
  Expression rhs;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the receiver is read-only and therefore doesn't need a
  /// temporary variable for its value.
  final bool readOnlyReceiver;

  /// The file offset for the read operation.
  final int readOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// The file offset for the write operation.
  final int writeOffset;

  CompoundPropertySet(
      this.receiver, this.propertyName, this.binaryName, this.rhs,
      {this.forEffect,
      this.readOnlyReceiver,
      this.readOffset,
      this.binaryOffset,
      this.writeOffset})
      : assert(forEffect != null),
        assert(readOnlyReceiver != null),
        assert(readOffset != null),
        assert(binaryOffset != null),
        assert(writeOffset != null) {
    receiver?.parent = this;
    rhs?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.CompoundPropertySet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing an compound property assignment.
///
/// An compound property assignment of the form `o.a++` is encoded as the
/// expression:
///
///     let v1 = o in let v2 = v1.a in let v3 = v1.a = v2 + 1 in v2
///
class PropertyPostIncDec extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  ///
  /// This is `null` if the receiver is read-only and therefore does not need to
  /// be stored in a temporary variable.
  VariableDeclaration variable;

  /// The expression that reads the property on [variable].
  VariableDeclaration read;

  /// The expression that writes the result of the binary operation to the
  /// property on [variable].
  VariableDeclaration write;

  PropertyPostIncDec(this.variable, this.read, this.write) {
    variable?.parent = this;
    read?.parent = this;
    write?.parent = this;
  }

  PropertyPostIncDec.onReadOnly(
      VariableDeclaration read, VariableDeclaration write)
      : this(null, read, write);

  @override
  InternalExpressionKind get kind => InternalExpressionKind.PropertyPostIncDec;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an local variable post inc/dec expression.
///
/// An local variable post inc/dec expression of the form `a++` is encoded as
/// the expression:
///
///     let v1 = a in let v2 = a = v1 + 1 in v1
///
class LocalPostIncDec extends InternalExpression {
  /// The expression that reads the local variable.
  VariableDeclaration read;

  /// The expression that writes the result of the binary operation to the
  /// local variable.
  VariableDeclaration write;

  LocalPostIncDec(this.read, this.write) {
    read?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.LocalPostIncDec;

  @override
  void visitChildren(Visitor<dynamic> v) {
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an static member post inc/dec expression.
///
/// An local variable post inc/dec expression of the form `a++` is encoded as
/// the expression:
///
///     let v1 = a in let v2 = a = v1 + 1 in v1
///
class StaticPostIncDec extends InternalExpression {
  /// The expression that reads the static member.
  VariableDeclaration read;

  /// The expression that writes the result of the binary operation to the
  /// static member.
  VariableDeclaration write;

  StaticPostIncDec(this.read, this.write) {
    read?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.StaticPostIncDec;

  @override
  void visitChildren(Visitor<dynamic> v) {
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an static member post inc/dec expression.
///
/// An local variable post inc/dec expression of the form `super.a++` is encoded
/// as the expression:
///
///     let v1 = super.a in let v2 = super.a = v1 + 1 in v1
///
class SuperPostIncDec extends InternalExpression {
  /// The expression that reads the static member.
  VariableDeclaration read;

  /// The expression that writes the result of the binary operation to the
  /// static member.
  VariableDeclaration write;

  SuperPostIncDec(this.read, this.write) {
    read?.parent = this;
    write?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.SuperPostIncDec;

  @override
  void visitChildren(Visitor<dynamic> v) {
    read?.accept(v);
    write?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (read != null) {
      read = read.accept<TreeNode>(v);
      read?.parent = this;
    }
    if (write != null) {
      write = write.accept<TreeNode>(v);
      write?.parent = this;
    }
  }
}

/// Internal expression representing an index set expression.
///
/// An index set expression of the form `o[a] = b` used for value is encoded as
/// the expression:
///
///     let v1 = o in let v2 = a in let v3 = b in let _ = o.[]=(v2, v3) in v3
///
/// An index set expression used for effect is encoded as
///
///    o.[]=(a, b)
///
/// using [MethodInvocationImpl].
///
class IndexSet extends InternalExpression {
  /// The receiver on which the index set operation is performed.
  Expression receiver;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  // TODO(johnniwinther): Add `readOnlyReceiver` capability.
  IndexSet(this.receiver, this.index, this.value) {
    receiver?.parent = this;
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing a  super index set expression.
///
/// A super index set expression of the form `super[a] = b` used for value is
/// encoded as the expression:
///
///     let v1 = a in let v2 = b in let _ = super.[]=(v1, v2) in v2
///
/// An index set expression used for effect is encoded as
///
///    super.[]=(a, b)
///
/// using [SuperMethodInvocation].
///
class SuperIndexSet extends InternalExpression {
  /// The []= member.
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  SuperIndexSet(this.setter, this.index, this.value) {
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.SuperIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing an extension index set expression.
///
/// An extension index set expression of the form `Extension(o)[a] = b` used
/// for value is encoded as the expression:
///
///     let receiverVariable = o
///     let indexVariable = a in
///     let valueVariable = b in '
///     let writeVariable =
///         receiverVariable.[]=(indexVariable, valueVariable) in
///           valueVariable
///
/// An extension index set expression used for effect is encoded as
///
///    o.[]=(a, b)
///
/// using [StaticInvocation].
///
class ExtensionIndexSet extends InternalExpression {
  /// The extension in which the [setter] is declared.
  final Extension extension;

  /// The explicit type arguments for the type parameters declared in
  /// [extension].
  final List<DartType> explicitTypeArguments;

  /// The receiver of the extension access.
  Expression receiver;

  /// The []= member.
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  ExtensionIndexSet(this.extension, this.explicitTypeArguments, this.receiver,
      this.setter, this.index, this.value)
      : assert(explicitTypeArguments == null ||
            explicitTypeArguments.length == extension.typeParameters.length) {
    receiver?.parent = this;
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.ExtensionIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing an if-null index assignment.
///
/// An if-null index assignment of the form `o[a] ??= b` is, if used for value,
/// encoded as the expression:
///
///     let v1 = o in
///     let v2 = a in
///     let v3 = v1[v2] in
///       v3 == null
///        ? (let v4 = b in
///           let _ = v1.[]=(v2, v4) in
///           v4)
///        : v3
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = o in
///     let v2 = a in
///     let v3 = v1[v2] in
///        v3 == null ? v1.[]=(v2, b) : null
///
/// If the [readOnlyReceiver] is true, no temporary variable is created for the
/// receiver and its use is inlined.
class IfNullIndexSet extends InternalExpression {
  /// The receiver on which the index set operation is performed.
  Expression receiver;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the == operation.
  final int testOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the receiver is read-only and therefore doesn't need a
  /// temporary variable for its value.
  final bool readOnlyReceiver;

  IfNullIndexSet(this.receiver, this.index, this.value,
      {this.readOffset,
      this.testOffset,
      this.writeOffset,
      this.forEffect,
      this.readOnlyReceiver: false})
      : assert(readOffset != null),
        assert(testOffset != null),
        assert(writeOffset != null),
        assert(forEffect != null) {
    receiver?.parent = this;
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IfNullIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing an if-null super index set expression.
///
/// An if-null super index set expression of the form `super[a] ??= b` is, if
/// used for value, encoded as the expression:
///
///     let v1 = a in
///     let v2 = super.[](v1) in
///       v2 == null
///        ? (let v3 = b in
///           let _ = super.[]=(v1, v3) in
///           v3)
///        : v2
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = a in
///     let v2 = super.[](v1) in
///        v2 == null ? super.[]=(v1, b) : null
///
class IfNullSuperIndexSet extends InternalExpression {
  /// The [] member;
  Member getter;

  /// The []= member;
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the == operation.
  final int testOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  IfNullSuperIndexSet(this.getter, this.setter, this.index, this.value,
      {this.readOffset, this.testOffset, this.writeOffset, this.forEffect})
      : assert(readOffset != null),
        assert(testOffset != null),
        assert(writeOffset != null),
        assert(forEffect != null) {
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.IfNullSuperIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing an if-null super index set expression.
///
/// An if-null super index set expression of the form `super[a] ??= b` is, if
/// used for value, encoded as the expression:
///
///     let v1 = a in
///     let v2 = super.[](v1) in
///       v2 == null
///        ? (let v3 = b in
///           let _ = super.[]=(v1, v3) in
///           v3)
///        : v2
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = a in
///     let v2 = super.[](v1) in
///        v2 == null ? super.[]=(v1, b) : null
///
class IfNullExtensionIndexSet extends InternalExpression {
  final Extension extension;

  final List<DartType> explicitTypeArguments;

  /// The extension receiver;
  Expression receiver;

  /// The [] member;
  Member getter;

  /// The []= member;
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The value expression of the operation.
  Expression value;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the == operation.
  final int testOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  IfNullExtensionIndexSet(this.extension, this.explicitTypeArguments,
      this.receiver, this.getter, this.setter, this.index, this.value,
      {this.readOffset, this.testOffset, this.writeOffset, this.forEffect})
      : assert(explicitTypeArguments == null ||
            explicitTypeArguments.length == extension.typeParameters.length),
        assert(readOffset != null),
        assert(testOffset != null),
        assert(writeOffset != null),
        assert(forEffect != null) {
    receiver?.parent = this;
    index?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.IfNullExtensionIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing a compound index assignment.
///
/// An if-null index assignment of the form `o[a] += b` is, if used for value,
/// encoded as the expression:
///
///     let v1 = o in
///     let v2 = a in
///     let v3 = v1.[](v2) + b
///     let v4 = v1.[]=(v2, c3) in v3
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = o in let v2 = a in v1.[]=(v2, v1.[](v2) + b)
///
class CompoundIndexSet extends InternalExpression {
  /// The receiver on which the index set operation is performed.
  Expression receiver;

  /// The index expression of the operation.
  Expression index;

  /// The name of the binary operation.
  Name binaryName;

  /// The right-hand side of the binary expression.
  Expression rhs;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the expression is a post-fix inc/dec expression.
  final bool forPostIncDec;

  /// If `true`, the receiver is read-only and therefore doesn't need a
  /// temporary variable for its value.
  final bool readOnlyReceiver;

  CompoundIndexSet(this.receiver, this.index, this.binaryName, this.rhs,
      {this.readOffset,
      this.binaryOffset,
      this.writeOffset,
      this.forEffect,
      this.forPostIncDec,
      this.readOnlyReceiver: false})
      : assert(forEffect != null) {
    receiver?.parent = this;
    index?.parent = this;
    rhs?.parent = this;
    fileOffset = binaryOffset;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.CompoundIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing a null-aware compound assignment.
///
/// A null-aware compound assignment of the form
///
///     receiver?.property binaryName= rhs
///
/// is, if used for value as a normal compound or prefix operation, encoded as
/// the expression:
///
///     let receiverVariable = receiver in
///       receiverVariable == null ? null :
///         let leftVariable = receiverVariable.propertyName in
///           let valueVariable = leftVariable binaryName rhs in
///             let writeVariable =
///                 receiverVariable.propertyName = valueVariable in
///               valueVariable
///
/// and, if used for value as a postfix operation, encoded as
///
///     let receiverVariable = receiver in
///       receiverVariable == null ? null :
///         let leftVariable = receiverVariable.propertyName in
///           let writeVariable =
///               receiverVariable.propertyName =
///                   leftVariable binaryName rhs in
///             leftVariable
///
/// and, if used for effect, encoded as:
///
///     let receiverVariable = receiver in
///       receiverVariable == null ? null :
///         receiverVariable.propertyName = receiverVariable.propertyName + rhs
///
class NullAwareCompoundSet extends InternalExpression {
  /// The receiver on which the null aware operation is performed.
  Expression receiver;

  /// The name of the null-aware property.
  Name propertyName;

  /// The name of the binary operation.
  Name binaryName;

  /// The right-hand side of the binary expression.
  Expression rhs;

  /// The file offset for the read operation.
  final int readOffset;

  /// The file offset for the write operation.
  final int writeOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the expression is a postfix inc/dec expression.
  final bool forPostIncDec;

  NullAwareCompoundSet(
      this.receiver, this.propertyName, this.binaryName, this.rhs,
      {this.readOffset,
      this.binaryOffset,
      this.writeOffset,
      this.forEffect,
      this.forPostIncDec})
      : assert(readOffset != null),
        assert(binaryOffset != null),
        assert(writeOffset != null),
        assert(forEffect != null),
        assert(forPostIncDec != null) {
    receiver?.parent = this;
    rhs?.parent = this;
    fileOffset = binaryOffset;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.NullAwareCompoundSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing an null-aware if-null property set.
///
/// A null-aware if-null property set of the form
///
///    receiver?.name ??= value
///
/// is, if used for value, encoded as the expression:
///
///     let receiverVariable = receiver in
///       receiverVariable == null ? null :
///         (let readVariable = receiverVariable.name in
///           readVariable == null ?
///             receiverVariable.name = value : readVariable)
///
/// and, if used for effect, encoded as the expression:
///
///     let receiverVariable = receiver in
///       receiverVariable == null ? null :
///         (receiverVariable.name == null ?
///           receiverVariable.name = value : null)
///
///
class NullAwareIfNullSet extends InternalExpression {
  /// The synthetic variable whose initializer hold the receiver.
  Expression receiver;

  /// The expression that reads the property from [variable].
  Name name;

  /// The expression that writes the value to the property on [variable].
  Expression value;

  /// The file offset for the read operation.
  final int readOffset;

  /// The file offset for the write operation.
  final int writeOffset;

  /// The file offset for the == operation.
  final int testOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  NullAwareIfNullSet(this.receiver, this.name, this.value,
      {this.readOffset, this.writeOffset, this.testOffset, this.forEffect})
      : assert(readOffset != null),
        assert(writeOffset != null),
        assert(testOffset != null),
        assert(forEffect != null) {
    receiver?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.NullAwareIfNullSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing a compound super index assignment.
///
/// An if-null index assignment of the form `super[a] += b` is, if used for
/// value, encoded as the expression:
///
///     let v1 = a in
///     let v2 = super.[](v1) + b
///     let v3 = super.[]=(v1, v2) in v2
///
/// and, if used for effect, encoded as the expression:
///
///     let v1 = a in super.[]=(v2, super.[](v2) + b)
///
class CompoundSuperIndexSet extends InternalExpression {
  /// The [] member.
  Member getter;

  /// The []= member.
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The name of the binary operation.
  Name binaryName;

  /// The right-hand side of the binary expression.
  Expression rhs;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the expression is a post-fix inc/dec expression.
  final bool forPostIncDec;

  CompoundSuperIndexSet(
      this.getter, this.setter, this.index, this.binaryName, this.rhs,
      {this.readOffset,
      this.binaryOffset,
      this.writeOffset,
      this.forEffect,
      this.forPostIncDec})
      : assert(forEffect != null) {
    index?.parent = this;
    rhs?.parent = this;
    fileOffset = binaryOffset;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.CompoundSuperIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    index?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing a compound extension index assignment.
///
/// An compound extension index assignment of the form `Extension(o)[a] += b`
/// is, if used for value, encoded as the expression:
///
///     let receiverVariable = o;
///     let indexVariable = a in
///     let valueVariable = receiverVariable.[](indexVariable) + b
///     let writeVariable =
///       receiverVariable.[]=(indexVariable, valueVariable) in
///         valueVariable
///
/// and, if used for effect, encoded as the expression:
///
///     let receiverVariable = o;
///     let indexVariable = a in
///         receiverVariable.[]=(indexVariable,
///             receiverVariable.[](indexVariable) + b)
///
class CompoundExtensionIndexSet extends InternalExpression {
  final Extension extension;

  final List<DartType> explicitTypeArguments;

  Expression receiver;

  /// The [] member.
  Member getter;

  /// The []= member.
  Member setter;

  /// The index expression of the operation.
  Expression index;

  /// The name of the binary operation.
  Name binaryName;

  /// The right-hand side of the binary expression.
  Expression rhs;

  /// The file offset for the [] operation.
  final int readOffset;

  /// The file offset for the []= operation.
  final int writeOffset;

  /// The file offset for the binary operation.
  final int binaryOffset;

  /// If `true`, the expression is only need for effect and not for its value.
  final bool forEffect;

  /// If `true`, the expression is a post-fix inc/dec expression.
  final bool forPostIncDec;

  CompoundExtensionIndexSet(
      this.extension,
      this.explicitTypeArguments,
      this.receiver,
      this.getter,
      this.setter,
      this.index,
      this.binaryName,
      this.rhs,
      {this.readOffset,
      this.binaryOffset,
      this.writeOffset,
      this.forEffect,
      this.forPostIncDec})
      : assert(explicitTypeArguments == null ||
            explicitTypeArguments.length == extension.typeParameters.length),
        assert(readOffset != null),
        assert(binaryOffset != null),
        assert(writeOffset != null),
        assert(forEffect != null),
        assert(forPostIncDec != null) {
    receiver?.parent = this;
    index?.parent = this;
    rhs?.parent = this;
    fileOffset = binaryOffset;
  }

  @override
  InternalExpressionKind get kind =>
      InternalExpressionKind.CompoundExtensionIndexSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    index?.accept(v);
    rhs?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (index != null) {
      index = index.accept<TreeNode>(v);
      index?.parent = this;
    }
    if (rhs != null) {
      rhs = rhs.accept<TreeNode>(v);
      rhs?.parent = this;
    }
  }
}

/// Internal expression representing an assignment to an extension setter.
///
/// An extension set of the form `receiver.target = value` is, if used for
/// value, encoded as the expression:
///
///     let receiverVariable = receiver in
///     let valueVariable = value in
///     let writeVariable = target(receiverVariable, valueVariable) in
///        valueVariable
///
/// or if the receiver is read-only, like `this` or a final variable,
///
///     let valueVariable = value in
///     let writeVariable = target(receiver, valueVariable) in
///        valueVariable
///
/// and, if used for effect, encoded as a [StaticInvocation]:
///
///     target(receiver, value)
///
// TODO(johnniwinther): Rename read-only to side-effect-free.
class ExtensionSet extends InternalExpression {
  final Extension extension;

  final List<DartType> explicitTypeArguments;

  /// The receiver for the assignment.
  Expression receiver;

  /// The extension member called for the assignment.
  Member target;

  /// The right-hand side value of the assignment.
  Expression value;

  /// If `true` the assignment is only needed for effect and not its result
  /// value.
  final bool forEffect;

  /// If `true` the receiver can be cloned instead of creating a temporary
  /// variable.
  final bool readOnlyReceiver;

  ExtensionSet(this.extension, this.explicitTypeArguments, this.receiver,
      this.target, this.value,
      {this.readOnlyReceiver, this.forEffect})
      : assert(explicitTypeArguments == null ||
            explicitTypeArguments.length == extension.typeParameters.length),
        assert(readOnlyReceiver != null),
        assert(forEffect != null) {
    receiver?.parent = this;
    value?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.ExtensionSet;

  @override
  void visitChildren(Visitor<dynamic> v) {
    receiver?.accept(v);
    value?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (receiver != null) {
      receiver = receiver.accept<TreeNode>(v);
      receiver?.parent = this;
    }
    if (value != null) {
      value = value.accept<TreeNode>(v);
      value?.parent = this;
    }
  }
}

/// Internal expression representing an null-aware extension expression.
///
/// An null-aware extension expression of the form `Extension(receiver)?.target`
/// is encoded as the expression:
///
///     let variable = receiver in
///       variable == null ? null : expression
///
/// where `expression` is an encoding of `receiverVariable.target`.
class NullAwareExtension extends InternalExpression {
  VariableDeclaration variable;
  Expression expression;

  NullAwareExtension(this.variable, this.expression) {
    variable?.parent = this;
    expression?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.NullAwareExtension;

  @override
  void visitChildren(Visitor<dynamic> v) {
    variable?.accept(v);
    expression?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (variable != null) {
      variable = variable.accept<TreeNode>(v);
      variable?.parent = this;
    }
    if (expression != null) {
      expression = expression.accept<TreeNode>(v);
      expression?.parent = this;
    }
  }
}

/// Front end specific implementation of [PropertySet].
class PropertySetImpl extends PropertySet {
  /// If `true` the assignment is need for its effect and not for its value.
  final bool forEffect;

  /// If `true` the receiver can be cloned and doesn't need a temporary variable
  /// for multiple reads.
  final bool readOnlyReceiver;

  PropertySetImpl(Expression receiver, Name name, Expression value,
      {Member interfaceTarget, this.forEffect, this.readOnlyReceiver})
      : assert(forEffect != null),
        super(receiver, name, value, interfaceTarget);
}

/// Internal representation of a read of an extension instance member.
///
/// A read of an extension instance member `o.foo` is encoded as the
/// [StaticInvocation]
///
///     extension|foo(o)
///
/// where `extension|foo` is the top level method created for reading the
/// `foo` member. If `foo` is an extension instance method, then `extension|foo`
/// the special tear-off function created for extension instance methods.
/// Otherwise `extension|foo` is the top level method corresponding to the
/// extension instance getter being read.
class ExtensionTearOff extends InternalExpression {
  /// The top-level method that is that target for the read operation.
  Member target;

  /// The arguments provided to the top-level method.
  Arguments arguments;

  ExtensionTearOff(this.target, this.arguments) {
    arguments?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.ExtensionTearOff;

  @override
  void visitChildren(Visitor<dynamic> v) {
    arguments?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (arguments != null) {
      arguments = arguments.accept<TreeNode>(v);
      arguments?.parent = this;
    }
  }
}

/// Internal expression for an equals or not-equals expression.
class EqualsExpression extends InternalExpression {
  Expression left;
  Expression right;
  bool isNot;

  EqualsExpression(this.left, this.right, {this.isNot})
      : assert(isNot != null) {
    left?.parent = this;
    right?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.Equals;

  @override
  void visitChildren(Visitor<dynamic> v) {
    left?.accept(v);
    right?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (left != null) {
      left = left.accept<TreeNode>(v);
      left?.parent = this;
    }
    if (right != null) {
      right = right.accept<TreeNode>(v);
      right?.parent = this;
    }
  }
}

/// Internal expression for a binary expression.
class BinaryExpression extends InternalExpression {
  Expression left;
  Name binaryName;
  Expression right;

  BinaryExpression(this.left, this.binaryName, this.right) {
    left?.parent = this;
    right?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.Binary;

  @override
  void visitChildren(Visitor<dynamic> v) {
    left?.accept(v);
    right?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (left != null) {
      left = left.accept<TreeNode>(v);
      left?.parent = this;
    }
    if (right != null) {
      right = right.accept<TreeNode>(v);
      right?.parent = this;
    }
  }
}

/// Internal expression for a unary expression.
class UnaryExpression extends InternalExpression {
  Name unaryName;
  Expression expression;

  UnaryExpression(this.unaryName, this.expression) {
    expression?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.Unary;

  @override
  void visitChildren(Visitor<dynamic> v) {
    expression?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (expression != null) {
      expression = expression.accept<TreeNode>(v);
      expression?.parent = this;
    }
  }
}

/// Internal expression for a parenthesized expression.
class ParenthesizedExpression extends InternalExpression {
  Expression expression;

  ParenthesizedExpression(this.expression) {
    expression?.parent = this;
  }

  @override
  InternalExpressionKind get kind => InternalExpressionKind.Parenthesized;

  @override
  void visitChildren(Visitor<dynamic> v) {
    expression?.accept(v);
  }

  @override
  void transformChildren(Transformer v) {
    if (expression != null) {
      expression = expression.accept<TreeNode>(v);
      expression?.parent = this;
    }
  }
}

/// Creates a [Let] of [variable] with the given [body] using
/// `variable.fileOffset` as the file offset for the let.
///
/// This is useful for create let expressions in replacement code.
Let createLet(VariableDeclaration variable, Expression body) {
  return new Let(variable, body)..fileOffset = variable.fileOffset;
}

/// Creates a [VariableDeclaration] for [expression] with the static [type]
/// using `expression.fileOffset` as the file offset for the declaration.
///
/// This is useful for creating let variables for expressions in replacement
/// code.
VariableDeclaration createVariable(Expression expression, DartType type) {
  return new VariableDeclaration.forValue(expression, type: type)
    ..fileOffset = expression.fileOffset;
}

/// Creates a [VariableDeclaration] for the expression inference [result]
/// using `result.expression.fileOffset` as the file offset for the declaration.
///
/// This is useful for creating let variables for expressions in replacement
/// code.
VariableDeclaration createVariableForResult(ExpressionInferenceResult result) {
  return createVariable(result.expression, result.inferredType);
}

/// Creates a [VariableGet] of [variable] using `variable.fileOffset` as the
/// file offset for the expression.
///
/// This is useful for referencing let variables for expressions in replacement
/// code.
VariableGet createVariableGet(VariableDeclaration variable) {
  return new VariableGet(variable)..fileOffset = variable.fileOffset;
}

/// Creates a `e == null` test for the expression [left] using the [fileOffset]
/// as file offset for the created nodes and [equalsMember] as the interface
/// target of the created method invocation.
MethodInvocation createEqualsNull(
    int fileOffset, Expression left, Member equalsMember) {
  return new MethodInvocation(
      left,
      equalsName,
      new Arguments(<Expression>[new NullLiteral()..fileOffset = fileOffset])
        ..fileOffset = fileOffset)
    ..fileOffset = fileOffset
    ..interfaceTarget = equalsMember;
}
