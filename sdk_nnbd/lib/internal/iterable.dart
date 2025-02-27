// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart._internal;

/**
 * Marker interface for [Iterable] subclasses that have an efficient
 * [length] implementation.
 */
abstract class EfficientLengthIterable<T> extends Iterable<T> {
  const EfficientLengthIterable();
  /**
   * Returns the number of elements in the iterable.
   *
   * This is an efficient operation that doesn't require iterating through
   * the elements.
   */
  int get length;
}

/**
 * An [Iterable] for classes that have efficient [length] and [elementAt].
 *
 * All other methods are implemented in terms of [length] and [elementAt],
 * including [iterator].
 */
abstract class ListIterable<E> extends EfficientLengthIterable<E> {
  int get length;
  E elementAt(int i);

  const ListIterable();

  Iterator<E> get iterator => new ListIterator<E>(this);

  void forEach(void action(E element)) {
    int length = this.length;
    for (int i = 0; i < length; i++) {
      action(elementAt(i));
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
  }

  bool get isEmpty => length == 0;

  E get first {
    if (length == 0) throw IterableElementError.noElement();
    return elementAt(0);
  }

  E get last {
    if (length == 0) throw IterableElementError.noElement();
    return elementAt(length - 1);
  }

  E get single {
    if (length == 0) throw IterableElementError.noElement();
    if (length > 1) throw IterableElementError.tooMany();
    return elementAt(0);
  }

  bool contains(Object? element) {
    int length = this.length;
    for (int i = 0; i < length; i++) {
      if (elementAt(i) == element) return true;
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    return false;
  }

  bool every(bool test(E element)) {
    int length = this.length;
    for (int i = 0; i < length; i++) {
      if (!test(elementAt(i))) return false;
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    return true;
  }

  bool any(bool test(E element)) {
    int length = this.length;
    for (int i = 0; i < length; i++) {
      if (test(elementAt(i))) return true;
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    return false;
  }

  E firstWhere(bool test(E element), {E Function()? orElse}) {
    int length = this.length;
    for (int i = 0; i < length; i++) {
      E element = elementAt(i);
      if (test(element)) return element;
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  E lastWhere(bool test(E element), {E Function()? orElse}) {
    int length = this.length;
    for (int i = length - 1; i >= 0; i--) {
      E element = elementAt(i);
      if (test(element)) return element;
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  E singleWhere(bool test(E element), {E Function()? orElse}) {
    int length = this.length;
    late E match;
    bool matchFound = false;
    for (int i = 0; i < length; i++) {
      E element = elementAt(i);
      if (test(element)) {
        if (matchFound) {
          throw IterableElementError.tooMany();
        }
        matchFound = true;
        match = element;
      }
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    if (matchFound) return match;
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  String join([String separator = ""]) {
    int length = this.length;
    if (!separator.isEmpty) {
      if (length == 0) return "";
      String first = "${elementAt(0)}";
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
      StringBuffer buffer = new StringBuffer(first);
      for (int i = 1; i < length; i++) {
        buffer.write(separator);
        buffer.write(elementAt(i));
        if (length != this.length) {
          throw new ConcurrentModificationError(this);
        }
      }
      return buffer.toString();
    } else {
      StringBuffer buffer = new StringBuffer();
      for (int i = 0; i < length; i++) {
        buffer.write(elementAt(i));
        if (length != this.length) {
          throw new ConcurrentModificationError(this);
        }
      }
      return buffer.toString();
    }
  }

  Iterable<E> where(bool test(E element)) => super.where(test);

  Iterable<T> map<T>(T f(E element)) => new MappedListIterable<E, T>(this, f);

  E reduce(E combine(E value, E element)) {
    int length = this.length;
    if (length == 0) throw IterableElementError.noElement();
    E value = elementAt(0);
    for (int i = 1; i < length; i++) {
      value = combine(value, elementAt(i));
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    return value;
  }

  T fold<T>(T initialValue, T combine(T previousValue, E element)) {
    var value = initialValue;
    int length = this.length;
    for (int i = 0; i < length; i++) {
      value = combine(value, elementAt(i));
      if (length != this.length) {
        throw new ConcurrentModificationError(this);
      }
    }
    return value;
  }

  Iterable<E> skip(int count) => new SubListIterable<E>(this, count, null);

  Iterable<E> skipWhile(bool test(E element)) => super.skipWhile(test);

  Iterable<E> take(int count) => new SubListIterable<E>(this, 0, count);

  Iterable<E> takeWhile(bool test(E element)) => super.takeWhile(test);

  List<E> toList({bool growable: true}) => List<E>.of(this, growable: growable);

  Set<E> toSet() {
    Set<E> result = new Set<E>();
    for (int i = 0; i < length; i++) {
      result.add(elementAt(i));
    }
    return result;
  }
}

class SubListIterable<E> extends ListIterable<E> {
  final Iterable<E> _iterable; // Has efficient length and elementAt.
  final int _start;
  /** If null, represents the length of the iterable. */
  final int? _endOrLength;

  SubListIterable(this._iterable, this._start, this._endOrLength) {
    RangeError.checkNotNegative(_start, "start");
    var endOrLength = _endOrLength;
    if (endOrLength != null) {
      RangeError.checkNotNegative(endOrLength, "end");
      if (_start > endOrLength) {
        throw new RangeError.range(_start, 0, endOrLength, "start");
      }
    }
  }

  int get _endIndex {
    int length = _iterable.length;
    int? endOrLength = _endOrLength;
    if (endOrLength == null || endOrLength > length) return length;
    return endOrLength;
  }

  int get _startIndex {
    int length = _iterable.length;
    if (_start > length) return length;
    return _start;
  }

  int get length {
    int length = _iterable.length;
    if (_start >= length) return 0;
    int? endOrLength = _endOrLength;
    if (endOrLength == null || endOrLength >= length) {
      return length - _start;
    }
    return endOrLength - _start;
  }

  E elementAt(int index) {
    int realIndex = _startIndex + index;
    if (index < 0 || realIndex >= _endIndex) {
      throw new RangeError.index(index, this, "index");
    }
    return _iterable.elementAt(realIndex);
  }

  Iterable<E> skip(int count) {
    RangeError.checkNotNegative(count, "count");
    int newStart = _start + count;
    var endOrLength = _endOrLength;
    if (endOrLength != null && newStart >= endOrLength) {
      return new EmptyIterable<E>();
    }
    return new SubListIterable<E>(_iterable, newStart, _endOrLength);
  }

  Iterable<E> take(int count) {
    RangeError.checkNotNegative(count, "count");
    int? endOrLength = _endOrLength;
    if (endOrLength == null) {
      return new SubListIterable<E>(_iterable, _start, _start + count);
    } else {
      int newEnd = _start + count;
      if (endOrLength < newEnd) return this;
      return new SubListIterable<E>(_iterable, _start, newEnd);
    }
  }

  List<E> toList({bool growable: true}) {
    int start = _start;
    int end = _iterable.length;
    int? endOrLength = _endOrLength;
    if (endOrLength != null && endOrLength < end) end = endOrLength;
    int length = end - start;
    if (length <= 0) return List<E>.empty(growable: growable);

    List<E> result =
        List<E>.filled(length, _iterable.elementAt(start), growable: growable);
    for (int i = 1; i < length; i++) {
      result[i] = _iterable.elementAt(start + i);
      if (_iterable.length < end) throw new ConcurrentModificationError(this);
    }
    return result;
  }
}

/**
 * An [Iterator] that iterates a list-like [Iterable].
 *
 * All iterations is done in terms of [Iterable.length] and
 * [Iterable.elementAt]. These operations are fast for list-like
 * iterables.
 */
class ListIterator<E> implements Iterator<E> {
  final Iterable<E> _iterable;
  final int _length;
  int _index;
  E? _current;

  ListIterator(Iterable<E> iterable)
      : _iterable = iterable,
        _length = iterable.length,
        _index = 0;

  E get current => _current as E;

  @pragma("vm:prefer-inline")
  bool moveNext() {
    int length = _iterable.length;
    if (_length != length) {
      throw new ConcurrentModificationError(_iterable);
    }
    if (_index >= length) {
      _current = null;
      return false;
    }
    _current = _iterable.elementAt(_index);
    _index++;
    return true;
  }
}

typedef T _Transformation<S, T>(S value);

class MappedIterable<S, T> extends Iterable<T> {
  final Iterable<S> _iterable;
  final _Transformation<S, T> _f;

  factory MappedIterable(Iterable<S> iterable, T function(S value)) {
    if (iterable is EfficientLengthIterable) {
      return new EfficientLengthMappedIterable<S, T>(iterable, function);
    }
    return new MappedIterable<S, T>._(iterable, function);
  }

  MappedIterable._(this._iterable, this._f);

  Iterator<T> get iterator => new MappedIterator<S, T>(_iterable.iterator, _f);

  // Length related functions are independent of the mapping.
  int get length => _iterable.length;
  bool get isEmpty => _iterable.isEmpty;

  // Index based lookup can be done before transforming.
  T get first => _f(_iterable.first);
  T get last => _f(_iterable.last);
  T get single => _f(_iterable.single);
  T elementAt(int index) => _f(_iterable.elementAt(index));
}

class EfficientLengthMappedIterable<S, T> extends MappedIterable<S, T>
    implements EfficientLengthIterable<T> {
  EfficientLengthMappedIterable(Iterable<S> iterable, T function(S value))
      : super._(iterable, function);
}

class MappedIterator<S, T> extends Iterator<T> {
  T? _current;
  final Iterator<S> _iterator;
  final _Transformation<S, T> _f;

  MappedIterator(this._iterator, this._f);

  bool moveNext() {
    if (_iterator.moveNext()) {
      _current = _f(_iterator.current);
      return true;
    }
    _current = null;
    return false;
  }

  T get current => _current as T;
}

/**
 * Specialized alternative to [MappedIterable] for mapped [List]s.
 *
 * Expects efficient `length` and `elementAt` on the source iterable.
 */
class MappedListIterable<S, T> extends ListIterable<T> {
  final Iterable<S> _source;
  final _Transformation<S, T> _f;

  MappedListIterable(this._source, this._f);

  int get length => _source.length;
  T elementAt(int index) => _f(_source.elementAt(index));
}

typedef bool _ElementPredicate<E>(E element);

class WhereIterable<E> extends Iterable<E> {
  final Iterable<E> _iterable;
  final _ElementPredicate<E> _f;

  WhereIterable(this._iterable, this._f);

  Iterator<E> get iterator => new WhereIterator<E>(_iterable.iterator, _f);

  // Specialization of [Iterable.map] to non-EfficientLengthIterable.
  Iterable<T> map<T>(T f(E element)) => new MappedIterable<E, T>._(this, f);
}

class WhereIterator<E> extends Iterator<E> {
  final Iterator<E> _iterator;
  final _ElementPredicate<E> _f;

  WhereIterator(this._iterator, this._f);

  bool moveNext() {
    while (_iterator.moveNext()) {
      if (_f(_iterator.current)) {
        return true;
      }
    }
    return false;
  }

  E get current => _iterator.current;
}

typedef Iterable<T> _ExpandFunction<S, T>(S sourceElement);

class ExpandIterable<S, T> extends Iterable<T> {
  final Iterable<S> _iterable;
  final _ExpandFunction<S, T> _f;

  ExpandIterable(this._iterable, this._f);

  Iterator<T> get iterator => new ExpandIterator<S, T>(_iterable.iterator, _f);
}

class ExpandIterator<S, T> implements Iterator<T> {
  final Iterator<S> _iterator;
  final _ExpandFunction<S, T> _f;
  // Initialize _currentExpansion to an empty iterable. A null value
  // marks the end of iteration, and we don't want to call _f before
  // the first moveNext call.
  Iterator<T>? _currentExpansion = const EmptyIterator<Never>();
  T? _current;

  ExpandIterator(this._iterator, this._f);

  T get current => _current as T;

  bool moveNext() {
    if (_currentExpansion == null) return false;
    while (!_currentExpansion!.moveNext()) {
      _current = null;
      if (_iterator.moveNext()) {
        // If _f throws, this ends iteration. Otherwise _currentExpansion and
        // _current will be set again below.
        _currentExpansion = null;
        _currentExpansion = _f(_iterator.current).iterator;
      } else {
        return false;
      }
    }
    _current = _currentExpansion!.current;
    return true;
  }
}

class TakeIterable<E> extends Iterable<E> {
  final Iterable<E> _iterable;
  final int _takeCount;

  factory TakeIterable(Iterable<E> iterable, int takeCount) {
    ArgumentError.checkNotNull(takeCount, "takeCount");
    RangeError.checkNotNegative(takeCount, "takeCount");
    if (iterable is EfficientLengthIterable) {
      return new EfficientLengthTakeIterable<E>(iterable, takeCount);
    }
    return new TakeIterable<E>._(iterable, takeCount);
  }

  TakeIterable._(this._iterable, this._takeCount);

  Iterator<E> get iterator {
    return new TakeIterator<E>(_iterable.iterator, _takeCount);
  }
}

class EfficientLengthTakeIterable<E> extends TakeIterable<E>
    implements EfficientLengthIterable<E> {
  EfficientLengthTakeIterable(Iterable<E> iterable, int takeCount)
      : super._(iterable, takeCount);

  int get length {
    int iterableLength = _iterable.length;
    if (iterableLength > _takeCount) return _takeCount;
    return iterableLength;
  }
}

class TakeIterator<E> extends Iterator<E> {
  final Iterator<E> _iterator;
  int _remaining;

  TakeIterator(this._iterator, this._remaining) {
    assert(_remaining >= 0);
  }

  bool moveNext() {
    _remaining--;
    if (_remaining >= 0) {
      return _iterator.moveNext();
    }
    _remaining = -1;
    return false;
  }

  E get current {
    if (_remaining < 0) throw IterableElementError.noElement();
    return _iterator.current;
  }
}

class TakeWhileIterable<E> extends Iterable<E> {
  final Iterable<E> _iterable;
  final _ElementPredicate<E> _f;

  TakeWhileIterable(this._iterable, this._f);

  Iterator<E> get iterator {
    return new TakeWhileIterator<E>(_iterable.iterator, _f);
  }
}

class TakeWhileIterator<E> extends Iterator<E> {
  final Iterator<E> _iterator;
  final _ElementPredicate<E> _f;
  bool _isFinished = false;

  TakeWhileIterator(this._iterator, this._f);

  bool moveNext() {
    if (_isFinished) return false;
    if (!_iterator.moveNext() || !_f(_iterator.current)) {
      _isFinished = true;
      return false;
    }
    return true;
  }

  E get current {
    if (_isFinished) throw IterableElementError.noElement();
    return _iterator.current;
  }
}

class SkipIterable<E> extends Iterable<E> {
  final Iterable<E> _iterable;
  final int _skipCount;

  factory SkipIterable(Iterable<E> iterable, int count) {
    if (iterable is EfficientLengthIterable) {
      return new EfficientLengthSkipIterable<E>(iterable, count);
    }
    return new SkipIterable<E>._(iterable, _checkCount(count));
  }

  SkipIterable._(this._iterable, this._skipCount);

  Iterable<E> skip(int count) {
    return new SkipIterable<E>._(_iterable, _skipCount + _checkCount(count));
  }

  Iterator<E> get iterator {
    return new SkipIterator<E>(_iterable.iterator, _skipCount);
  }
}

class EfficientLengthSkipIterable<E> extends SkipIterable<E>
    implements EfficientLengthIterable<E> {
  factory EfficientLengthSkipIterable(Iterable<E> iterable, int count) {
    return new EfficientLengthSkipIterable<E>._(iterable, _checkCount(count));
  }

  EfficientLengthSkipIterable._(Iterable<E> iterable, int count)
      : super._(iterable, count);

  int get length {
    int length = _iterable.length - _skipCount;
    if (length >= 0) return length;
    return 0;
  }

  Iterable<E> skip(int count) {
    return new EfficientLengthSkipIterable<E>._(
        _iterable, _skipCount + _checkCount(count));
  }
}

int _checkCount(int count) {
  ArgumentError.checkNotNull(count, "count");
  RangeError.checkNotNegative(count, "count");
  return count;
}

class SkipIterator<E> extends Iterator<E> {
  final Iterator<E> _iterator;
  int _skipCount;

  SkipIterator(this._iterator, this._skipCount) {
    assert(_skipCount >= 0);
  }

  bool moveNext() {
    for (int i = 0; i < _skipCount; i++) _iterator.moveNext();
    _skipCount = 0;
    return _iterator.moveNext();
  }

  E get current => _iterator.current;
}

class SkipWhileIterable<E> extends Iterable<E> {
  final Iterable<E> _iterable;
  final _ElementPredicate<E> _f;

  SkipWhileIterable(this._iterable, this._f);

  Iterator<E> get iterator {
    return new SkipWhileIterator<E>(_iterable.iterator, _f);
  }
}

class SkipWhileIterator<E> extends Iterator<E> {
  final Iterator<E> _iterator;
  final _ElementPredicate<E> _f;
  bool _hasSkipped = false;

  SkipWhileIterator(this._iterator, this._f);

  bool moveNext() {
    if (!_hasSkipped) {
      _hasSkipped = true;
      while (_iterator.moveNext()) {
        if (!_f(_iterator.current)) return true;
      }
    }
    return _iterator.moveNext();
  }

  E get current => _iterator.current;
}

/**
 * The always empty [Iterable].
 */
class EmptyIterable<E> extends EfficientLengthIterable<E> {
  const EmptyIterable();

  Iterator<E> get iterator => const EmptyIterator<Never>();

  void forEach(void action(E element)) {}

  bool get isEmpty => true;

  int get length => 0;

  E get first {
    throw IterableElementError.noElement();
  }

  E get last {
    throw IterableElementError.noElement();
  }

  E get single {
    throw IterableElementError.noElement();
  }

  E elementAt(int index) {
    throw new RangeError.range(index, 0, 0, "index");
  }

  bool contains(Object? element) => false;

  bool every(bool test(E element)) => true;

  bool any(bool test(E element)) => false;

  E firstWhere(bool test(E element), {E Function()? orElse}) {
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  E lastWhere(bool test(E element), {E Function()? orElse}) {
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  E singleWhere(bool test(E element), {E Function()? orElse}) {
    if (orElse != null) return orElse();
    throw IterableElementError.noElement();
  }

  String join([String separator = ""]) => "";

  Iterable<E> where(bool test(E element)) => this;

  Iterable<T> map<T>(T f(E element)) => new EmptyIterable<T>();

  E reduce(E combine(E value, E element)) {
    throw IterableElementError.noElement();
  }

  T fold<T>(T initialValue, T combine(T previousValue, E element)) {
    return initialValue;
  }

  Iterable<E> skip(int count) {
    RangeError.checkNotNegative(count, "count");
    return this;
  }

  Iterable<E> skipWhile(bool test(E element)) => this;

  Iterable<E> take(int count) {
    RangeError.checkNotNegative(count, "count");
    return this;
  }

  Iterable<E> takeWhile(bool test(E element)) => this;

  List<E> toList({bool growable: true}) => List<E>.empty(growable: growable);

  Set<E> toSet() => new Set<E>();
}

/** The always empty iterator. */
class EmptyIterator<E> implements Iterator<E> {
  const EmptyIterator();
  bool moveNext() => false;
  E get current {
    throw IterableElementError.noElement();
  }
}

class FollowedByIterable<E> extends Iterable<E> {
  final EfficientLengthIterable<E> _first;
  final Iterable<E> _second;
  FollowedByIterable(this._first, this._second);

  factory FollowedByIterable.firstEfficient(
      EfficientLengthIterable<E> first, Iterable<E> second) {
    if (second is EfficientLengthIterable<E>) {
      return new EfficientLengthFollowedByIterable<E>(first, second);
    }
    return new FollowedByIterable<E>(first, second);
  }

  Iterator<E> get iterator => new FollowedByIterator(_first, _second);

  int get length => _first.length + _second.length;
  bool get isEmpty => _first.isEmpty && _second.isEmpty;
  bool get isNotEmpty => _first.isNotEmpty || _second.isNotEmpty;

  // May be more efficient if either iterable is a Set.
  bool contains(Object? value) =>
      _first.contains(value) || _second.contains(value);

  E get first {
    var iterator = _first.iterator;
    if (iterator.moveNext()) return iterator.current;
    return _second.first;
  }

  E get last {
    var iterator = _second.iterator;
    if (iterator.moveNext()) {
      E last = iterator.current;
      while (iterator.moveNext()) last = iterator.current;
      return last;
    }
    return _first.last;
  }

  // If linear sequences of `followedBy` becomes an issue, we can flatten
  // into a list of iterables instead of a tree or spine.
}

class EfficientLengthFollowedByIterable<E> extends FollowedByIterable<E>
    implements EfficientLengthIterable<E> {
  EfficientLengthFollowedByIterable(
      EfficientLengthIterable<E> first, EfficientLengthIterable<E> second)
      : super(first, second);

  E elementAt(int index) {
    int firstLength = _first.length;
    if (index < firstLength) return _first.elementAt(index);
    return _second.elementAt(index - firstLength);
  }

  E get first {
    if (_first.isNotEmpty) return _first.first;
    return _second.first;
  }

  E get last {
    if (_second.isNotEmpty) return _second.last;
    return _first.last;
  }
}

class FollowedByIterator<E> implements Iterator<E> {
  Iterator<E> _currentIterator;
  Iterable<E>? _nextIterable;

  FollowedByIterator(Iterable<E> first, this._nextIterable)
      : _currentIterator = first.iterator;

  bool moveNext() {
    if (_currentIterator.moveNext()) return true;
    if (_nextIterable != null) {
      _currentIterator = _nextIterable!.iterator;
      _nextIterable = null;
      return _currentIterator.moveNext();
    }
    return false;
  }

  E get current => _currentIterator.current;
}

class WhereTypeIterable<T> extends Iterable<T> {
  final Iterable<Object> _source;
  WhereTypeIterable(this._source);
  Iterator<T> get iterator => new WhereTypeIterator<T>(_source.iterator);
}

class WhereTypeIterator<T> implements Iterator<T> {
  final Iterator<Object> _source;
  WhereTypeIterator(this._source);
  bool moveNext() {
    while (_source.moveNext()) {
      if (_source.current is T) return true;
    }
    return false;
  }

  T get current => _source.current as T;
}

/**
 * Creates errors throw by [Iterable] when the element count is wrong.
 */
abstract class IterableElementError {
  /** Error thrown thrown by, e.g., [Iterable.first] when there is no result. */
  static StateError noElement() => new StateError("No element");
  /** Error thrown by, e.g., [Iterable.single] if there are too many results. */
  static StateError tooMany() => new StateError("Too many elements");
  /** Error thrown by, e.g., [List.setRange] if there are too few elements. */
  static StateError tooFew() => new StateError("Too few elements");
}
