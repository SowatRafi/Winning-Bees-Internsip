import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart'
    show MissingPlatformDirectoryException, getApplicationDocumentsDirectory;
import 'package:path/path.dart' show join;
import 'package:my_notes/services/curd/crud_exceptions.dart';

class NoteService {
  Database? _db;

  List<DatabaseNote> _notes = [];
  static final NoteService _shared = NoteService._sharedInstance();
  NoteService._sharedInstance();
  factory NoteService() => _shared;

  late final StreamController<List<DatabaseNote>> _notesStreamController;
  // Get all notes
  Stream<List<DatabaseNote>> get allNotes => _notesStreamController.stream;

  Database _getDatabaseOrThrow() {
    final db = _db;
    if (db == null) {
      throw DatabaseIsNotOpen();
    } else {
      return db;
    }
  }

  // get or create user
  Future<DatabaseUser> getOrCreateUser({required String email}) async {
    try {
      final user = await getUser(email: email);
      return user;
    } on CouldNotFindUser {
      final createdUser = await createUser(email: email);
      return createdUser;
    } catch (e) {
      rethrow;
    }
  }

  // cache notes
  Future<void> _cacheNotes() async {
    final allNotes = await getAllNotes();
    _notes = allNotes.toList();
    _notesStreamController.add(_notes);
  }

  // update note
  Future<DatabaseNote> updateNote({
    required DatabaseNote note,
    required String text,
  }) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    // make sure note exist
    await getNote(id: note.id);
    // update DB
    final updatesCount = await db.update(noteTable, {
      textColumn: text,
      isSyncedWithCloudColumn: 0,
    });

    if (updatesCount == 0) {
      throw CouldNotUpdateNote();
    } else {
      final updatedNote = await getNote(id: note.id);
      _notes.removeWhere((note) => note.id == updatedNote.id);
      _notes.add(updatedNote);
      _notesStreamController.add(_notes);
      return updatedNote;
    }
  }

  // get all the notes
  Future<Iterable<DatabaseNote>> getAllNotes() async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final notes = await db.query(noteTable);

    return notes.map((noteRow) => DatabaseNote.fromRow(noteRow));
  }

  // get the notes
  Future<DatabaseNote> getNote({required int id}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final notes = await db.query(
      noteTable,
      limit: 1,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (notes.isEmpty) {
      throw CouldNotFindNote();
    } else {
      final note = DatabaseNote.fromRow(notes.first);
      _notes.removeWhere((note) => note.id == id);
      _notes.add(note);
      _notesStreamController.add(_notes);
      return note;
    }
  }

  // delete all notes
  Future<int> deleteAllNotes() async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final numberOfDeletions = await db.delete(noteTable);
    _notes = [];
    _notesStreamController.add(_notes);
    return numberOfDeletions;
  }

  // delete note
  Future<void> deleteNote({required int id}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final deletedCount = await db.delete(
      noteTable,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (deletedCount == 0) {
      throw CouldNotDeleteNote();
    } else {
      final countBefore = _notes.length;
      _notes.removeWhere((note) => note.id == id);
      if (_notes.length != countBefore) {
        _notesStreamController.add(_notes);
      }
    }
  }

  // create new notes
  Future<DatabaseNote> createNote({required DatabaseUser owner}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();

    // make sure owner exists in the database with the correct id
    final dbUser = await getUser(email: owner.email);
    if (dbUser != owner) {
      throw CouldNotFindUser();
    }

    const text = '';
    // create the note
    final noteId = await db.insert(noteTable, {
      userIdColumn: owner.id,
      textColumn: text,
      isSyncedWithCloudColumn: 1,
    });

    final note = DatabaseNote(
      id: noteId,
      userID: owner.id,
      text: text,
      isSyncedWithCloud: true,
    );

    _notes.add(note);
    _notesStreamController.add(_notes);

    return note;
  }

  // fetch user
  Future<DatabaseUser> getUser({required String email}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();

    final results = await db.query(
      userTable,
      limit: 1,
      where: 'email = ?',
      whereArgs: [email.toLowerCase()],
    );

    if (results.isEmpty) {
      throw CouldNotDeleteUser();
    } else {
      return DatabaseUser.fromRow(results.first);
    }
  }

  // create user
  Future<DatabaseUser> createUser({required String email}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final results = await db.query(
      userTable,
      limit: 1,
      where: 'email = ?',
      whereArgs: [email.toLowerCase()],
    );
    if (results.isNotEmpty) {
      throw UserAlreadyExists();
    }
    final userID = await db.insert(userTable, {
      emailColumn: email.toLowerCase(),
    });

    return DatabaseUser(
      id: userID,
      email: email,
    );
  }

  // delete user
  Future<void> deleteUser({required String email}) async {
    await _ensureDBIsOpen();

    final db = _getDatabaseOrThrow();
    final deletedCount = await db.delete(
      userTable,
      where: 'email = ?',
      whereArgs: [email.toLowerCase()],
    );
    if (deletedCount != 1) {
      throw CouldNotDeleteUser();
    }
  }

  // close database
  Future<void> close() async {
    final db = _db;
    if (db == null) {
      throw DatabaseIsNotOpen();
    } else {
      await db.close();
      _db = null;
    }
  }

  Future<void> _ensureDBIsOpen() async {
    try {
      await open();
    } on DatabaseAlreadyOpenException {
      // empty
    }
  }

  // open database
  Future<void> open() async {
    if (_db != null) {
      throw DatabaseAlreadyOpenException();
    }
    try {
      final docsPath = await getApplicationDocumentsDirectory();
      final dbPath = join(docsPath.path, dbName);
      final db = await openDatabase(dbPath);
      _db = db;
      // create the user table
      await db.execute(createUserTable);
      // create the note table
      await db.execute(createNoteTable);
      await _cacheNotes();
    } on MissingPlatformDirectoryException {
      throw UnableToGetDocumentsDirectory();
    }
  }
}

@immutable
class DatabaseUser {
  final int id;
  final String email;

  const DatabaseUser({
    required this.id,
    required this.email,
  });
  // When we talk with the database, we are going to read like hash tables for every row that we read from that table, so, every user inside the database table called user is going to be represented by this object a map of a String and an optional object. That's the row inside the user table.
  // This node service that we're going to create soon reads this users from the database and it should be able to pass this to our databaseUser class and the databaseUser Class should create an instance of itself.
  DatabaseUser.fromRow(Map<String, Object?> map)
      : id = map[idColumn] as int,
        email = map[emailColumn] as String;

  @override
  // for getting the person id and email in String
  String toString() => 'Person, ID = $id, email = $email';
  @override
  // change the == glitch
  bool operator ==(covariant DatabaseUser other) => id == other.id;

  @override
  // hashCode
  int get hashCode => id.hashCode;
}

class DatabaseNote {
  final int id;
  final int userID;
  final String text;
  final bool isSyncedWithCloud;

  DatabaseNote({
    required this.id,
    required this.userID,
    required this.text,
    required this.isSyncedWithCloud,
  });

  DatabaseNote.fromRow(Map<String, Object?> map)
      : id = map[idColumn] as int,
        userID = map[userIdColumn] as int,
        text = map[textColumn] as String,
        isSyncedWithCloud =
            (map[isSyncedWithCloudColumn] as int) == 1 ? true : false;

  @override
  String toString() =>
      'Note, ID = $id, userID = $userID, isSyncedWithCloud = $isSyncedWithCloud \ntext: $text';

  @override
  // ==
  bool operator ==(covariant DatabaseNote other) => id == other.id;

  @override
  // hashCode
  int get hashCode => id.hashCode;
}

// Database Name
const dbName = 'notes.db';
// Tables names
const noteTable = 'note';
const userTable = 'user';
// table elements names
const idColumn = 'id';
const emailColumn = 'email';
const userIdColumn = 'user_id';
const textColumn = 'text';
const isSyncedWithCloudColumn = 'is_synced_with_cloud';
// sql commands
const createUserTable = '''
                            CREATE TABLE IF NOT EXISTS "user" ("id" INTEGER NOT NULL,
                                                               "email" TEXT NOT NULL UNIQUE,
                                                               PRIMARY KEY("id" AUTOINCREMENT)
                                                               );
                        ''';
const createNoteTable = '''
                            CREATE TABLE IF NOT EXISTS "note" ("id"	INTEGER NOT NULL,
                                                               "user_id"	INTEGER NOT NULL,
                                                               "text"	TEXT,
                                                               "is_synced_with_cloud"	INTEGER NOT NULL DEFAULT 0,
                                                               PRIMARY KEY("id" AUTOINCREMENT),
                                                               FOREIGN KEY("user_id") REFERENCES "user"("id")
                                                               );
                        ''';
