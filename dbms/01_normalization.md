# InterAct – Database Normalization

## 1. Project Overview

InterAct is an AI-powered interview practice platform. Users can prepare for interviews using a topic or an uploaded PDF/TXT document. The platform generates questions based on the selected difficulty and interview style. Users submit their answers, receive AI-based evaluations, and view a final performance report.

The purpose of normalization is to organize database information properly, reduce unnecessary duplication, and maintain consistency between related records.

**Design note:** This document presents a proposed logical database design based on the current InterAct project features. The application does not yet have a finalized PostgreSQL schema. Therefore, the tables, attributes, and functional dependencies described below are design assumptions to be verified during implementation.

## 2. Main Entities

The proposed database contains the following entities:

| Entity | Purpose |
|---|---|
| Users | Stores user account information |
| Documents | Stores uploaded document information |
| Document_chunks | Stores smaller sections extracted from documents |
| Document_topics | Stores topics identified in documents |
| Sessions | Stores interview practice sessions |
| Preparation_messages | Stores preparation conversation messages |
| Rubrics | Stores evaluation criteria |
| Questions | Stores generated or selected questions |
| Answers | Stores users' responses |
| Evaluations | Stores AI evaluation results |
| Reports | Stores session performance summaries |
| Jobs | Tracks background processing tasks |
| LLM_calls | Tracks AI model requests |
| Experiment_runs | Stores AI experiment information |

## 3. Unnormalized Form (UNF)

Initially, imagine storing all interview practice information in one large record.

For example:

**Practice_Record**

- User_ID
- User_Name
- User_Email
- Session_ID
- Session_Date
- Difficulty
- Interview_Style
- Document_Name
- Document_Chunks (multiple values)
- Topics (multiple values)
- Questions (multiple values)
- Answers (multiple values)
- Evaluation_Scores (multiple values)
- Feedback (multiple values)
- Report_Summary

This structure creates problems because one interview session can contain multiple questions, answers, and evaluations. Storing these as repeated groups makes searching and updating information difficult.

For example, adding a new question may require modifying an existing record containing several other questions and answers.

Therefore, the data needs to be normalized.

## 4. First Normal Form (1NF)

A table is in First Normal Form (1NF) when:

1. Each column contains a single, atomic value.
2. There are no repeating groups or multiple values in one cell.
3. Each record can be uniquely identified.

To achieve 1NF, multiple questions, answers, and evaluation results are represented as separate rows rather than lists inside a single record.

For example:

**Practice_Record_1NF**

| Session_ID | Question_ID | User_ID | User_Email | Session_Date | Difficulty | Interview_Style | Question_Text | Answer_Text | Score |
|---|---|---|---|---|---|---|---|---|---:|
| S01 | Q01 | U01 | user@example.com | 2026-11-01 | Easy | Technical | Explain DBMS | DBMS manages data | 8 |
| S01 | Q02 | U01 | user@example.com | 2026-11-01 | Easy | Technical | Explain SQL | SQL queries databases | 7 |
| S02 | Q01 | U01 | user@example.com | 2026-11-02 | Medium | HR | Explain Python | Python is a language | 9 |

**Primary Key:** (Session_ID, Question_ID)

This design assumes that a question can have only one final answer in a particular session.

All values are atomic, and each row can be uniquely identified using the composite primary key.

However, some information is repeated. For example, user and session details may appear in multiple rows.

### 4.1 Functional Dependencies in 1NF

The following functional dependencies are assumed:

- Session_ID → User_ID, User_Email, Session_Date, Difficulty, Interview_Style
- Question_ID → Question_Text
- (Session_ID, Question_ID) → Answer_Text, Score

The composite key determines the answer and score, but some non-key attributes depend on only part of the composite key.

For example:

- Session_ID determines the session details.
- Question_ID determines the question text.

These are partial dependencies.

Therefore, the table satisfies 1NF but does not satisfy 2NF.

## 5. Second Normal Form (2NF)

A table is in Second Normal Form (2NF) when:

1. It is already in 1NF.
2. Every non-key attribute depends on the whole candidate key, not just part of it.

In the 1NF table, the primary key is:

(Session_ID, Question_ID)

However:

- Session_ID alone determines session-related information.
- Question_ID alone determines question-related information.
- The combination of Session_ID and Question_ID determines the answer and score.

These are partial dependencies because some non-key attributes depend on only part of the composite key.

To remove these partial dependencies, the information is divided into separate tables.

### 5.1 Sessions

| Session_ID (PK) | User_ID | User_Email | Session_Date | Difficulty | Interview_Style |
|---|---|---|---|---|---|

**Functional Dependency:**

Session_ID → User_ID, User_Email, Session_Date, Difficulty, Interview_Style

### 5.2 Questions

| Question_ID (PK) | Question_Text | Rubric_ID | Rubric_Name |
|---|---|---|---|

**Functional Dependency:**

Question_ID → Question_Text, Rubric_ID, Rubric_Name

### 5.3 Answers

| Session_ID (PK, FK) | Question_ID (PK, FK) | Answer_Text | Score |
|---|---|---|---:|

**Composite Primary Key:** (Session_ID, Question_ID)

**Functional Dependency:**

(Session_ID, Question_ID) → Answer_Text, Score

Now, session information, question information, and answer information are stored separately.

The partial dependencies have been removed because each non-key attribute in these tables depends on the entire key.

However, some transitive dependencies still exist:

- Session_ID → User_ID → User_Email
- Question_ID → Rubric_ID → Rubric_Name

These dependencies need to be removed to achieve 3NF.

## 6. Third Normal Form (3NF)

A table is in Third Normal Form (3NF) when:

1. It is already in 2NF.
2. It has no transitive dependency of non-key attributes on a candidate key.

To achieve 3NF, user information is separated from sessions, and rubric information is separated from questions.

The final proposed tables are described below.

### 6.1 Users

| Column | Description |
|---|---|
| user_id (PK) | Unique user identifier |
| full_name | User's name |
| email (UNIQUE) | User's email |
| password_hash | Stored password hash |
| auth_provider | Authentication provider |
| created_at | Account creation time |

**Functional Dependency:**

user_id → full_name, email, password_hash, auth_provider, created_at

**Additional candidate key:** email

This assumes each email address belongs to only one account.

### 6.2 Documents

| Column | Description |
|---|---|
| document_id (PK) | Unique document identifier |
| user_id (FK) | Owner of the document |
| file_name | Uploaded file name |
| file_type | PDF or TXT |
| storage_path | Document storage location |
| uploaded_at | Upload time |

**Functional Dependency:**

document_id → user_id, file_name, file_type, storage_path, uploaded_at

### 6.3 Document_chunks

| Column | Description |
|---|---|
| chunk_id (PK) | Unique chunk identifier |
| document_id (FK) | Related document |
| chunk_index | Position of the chunk |
| chunk_text | Extracted text |

**Functional Dependencies:**

- chunk_id → document_id, chunk_index, chunk_text
- (document_id, chunk_index) → chunk_id, chunk_text

The second dependency assumes that a document cannot contain two chunks with the same position.

### 6.4 Document_topics

| Column | Description |
|---|---|
| document_id (PK, FK) | Related document |
| topic_name (PK) | Topic identified in the document |

**Composite Primary Key:** (document_id, topic_name)

There are no non-key attributes in this table, so it has no non-trivial functional dependencies.

### 6.5 Sessions

| Column | Description |
|---|---|
| session_id (PK) | Unique session identifier |
| user_id (FK) | User who started the session |
| document_id (FK, nullable) | Uploaded document, if used |
| topic_name | Selected practice topic |
| difficulty | Selected difficulty |
| interview_style | Selected interview style |
| status | Session status |
| started_at | Session start time |
| completed_at | Session completion time |

**Functional Dependency:**

session_id → user_id, document_id, topic_name, difficulty, interview_style, status, started_at, completed_at

### 6.6 Preparation_messages

| Column | Description |
|---|---|
| message_id (PK) | Unique message identifier |
| session_id (FK) | Related session |
| role | Message sender role |
| message_text | Message content |
| created_at | Message time |

**Functional Dependency:**

message_id → session_id, role, message_text, created_at

### 6.7 Rubrics

| Column | Description |
|---|---|
| rubric_id (PK) | Unique rubric identifier |
| rubric_name | Name of the evaluation rubric |
| description | Evaluation criteria description |

**Functional Dependency:**

rubric_id → rubric_name, description

### 6.8 Questions

| Column | Description |
|---|---|
| question_id (PK) | Unique question identifier |
| rubric_id (FK) | Associated evaluation rubric |
| question_text | Question content |
| difficulty | Question difficulty |
| question_type | Type of question |

**Functional Dependency:**

question_id → rubric_id, question_text, difficulty, question_type

### 6.9 Answers

| Column | Description |
|---|---|
| session_id (PK, FK) | Related interview session |
| question_id (PK, FK) | Related question |
| answer_text | User's answer |
| submitted_at | Submission time |

**Composite Primary Key:** (session_id, question_id)

**Functional Dependency:**

(session_id, question_id) → answer_text, submitted_at

This design assumes one final answer per question in each session.

### 6.10 Evaluations

| Column | Description |
|---|---|
| session_id (PK, FK) | Related answer's session |
| question_id (PK, FK) | Related answer's question |
| score | Evaluation score |
| feedback | AI-generated feedback |
| evaluated_at | Evaluation time |

**Composite Primary Key:** (session_id, question_id)

The composite foreign key (session_id, question_id) references the corresponding record in Answers.

**Functional Dependency:**

(session_id, question_id) → score, feedback, evaluated_at

This design assumes that each answer receives one final evaluation.

### 6.11 Reports

| Column | Description |
|---|---|
| report_id (PK) | Unique report identifier |
| session_id (FK, UNIQUE) | Related session |
| overall_score | Overall performance score |
| summary | Performance summary |
| generated_at | Report generation time |

**Functional Dependency:**

report_id → session_id, overall_score, summary, generated_at

**Additional candidate key:** session_id

This assumes each session has only one final report.

### 6.12 Jobs

| Column | Description |
|---|---|
| job_id (PK) | Unique job identifier |
| user_id (FK) | User requesting the job |
| job_type | Type of background task |
| status | Current job status |
| created_at | Creation time |
| completed_at | Completion time |

**Functional Dependency:**

job_id → user_id, job_type, status, created_at, completed_at

### 6.13 LLM_calls

| Column | Description |
|---|---|
| llm_call_id (PK) | Unique AI call identifier |
| job_id (FK, nullable) | Related background job |
| session_id (FK, nullable) | Related practice session |
| operation | AI operation performed |
| model_name | AI model used |
| input_tokens | Input token count |
| output_tokens | Output token count |
| latency_ms | Request latency |
| created_at | Request time |

**Functional Dependency:**

llm_call_id → job_id, session_id, operation, model_name, input_tokens, output_tokens, latency_ms, created_at

### 6.14 Experiment_runs

| Column | Description |
|---|---|
| experiment_run_id (PK) | Unique experiment identifier |
| experiment_name | Experiment name |
| model_name | Model used |
| prompt_version | Prompt version |
| started_at | Experiment start time |
| completed_at | Completion time |

**Functional Dependency:**

experiment_run_id → experiment_name, model_name, prompt_version, started_at, completed_at

## 7. Boyce-Codd Normal Form (BCNF)

Boyce-Codd Normal Form (BCNF) is a stronger version of 3NF.

A relation is in BCNF when every non-trivial functional dependency has a determinant that is a candidate key.

In the proposed design, the following candidate keys and uniqueness assumptions are used:

| Table | Candidate Key / Unique Constraint |
|---|---|
| Users | user_id, email |
| Documents | document_id |
| Document_chunks | chunk_id, (document_id, chunk_index) |
| Document_topics | (document_id, topic_name) |
| Sessions | session_id |
| Preparation_messages | message_id |
| Rubrics | rubric_id |
| Questions | question_id |
| Answers | (session_id, question_id) |
| Evaluations | (session_id, question_id) |
| Reports | report_id, session_id |
| Jobs | job_id |
| LLM_calls | llm_call_id |
| Experiment_runs | experiment_run_id |

Examples of functional dependencies whose determinants are candidate keys:

- Users: user_id → user details; email → user details.
- Document_chunks: chunk_id → chunk details; (document_id, chunk_index) → chunk details.
- Answers: (session_id, question_id) → answer details.
- Evaluations: (session_id, question_id) → evaluation details.
- Reports: report_id → report details; session_id → report details.

Under these assumptions, every listed non-trivial functional dependency has a candidate key as its determinant. Therefore, the proposed relations are designed to satisfy BCNF.

This conclusion depends on the stated uniqueness assumptions and should be verified against the final application requirements.

## 8. Final Normalization Summary

| Normal Form | What was done |
|---|---|
| UNF | Multiple questions, answers, and evaluations were grouped together |
| 1NF | Repeating groups were removed and values made atomic |
| 2NF | Partial dependencies were removed by separating session, question, and answer information |
| 3NF | Transitive dependencies were removed by separating users and rubrics |
| BCNF | Determinants were checked against candidate keys and uniqueness rules |

## 9. Design Assumptions and Limitations

The proposed design is based on the current understanding of InterAct's features.

The following assumptions have been made:

1. A user can create multiple interview practice sessions.
2. A session can use a selected topic or an uploaded document.
3. A session can contain multiple questions.
4. A question has one final answer in a particular session.
5. Each answer receives one final evaluation.
6. Each completed session has one final performance report.
7. A document can be divided into multiple chunks.
8. A document can have multiple identified topics.
9. AI requests and background jobs can be tracked separately.

If the application supports multiple answer attempts, multiple evaluations, or multiple reports for the same session, the corresponding primary keys and uniqueness assumptions must be updated.

The final database schema should be checked against the implemented application before deployment.

## 10. Conclusion

Normalization helps InterAct maintain structured and consistent information. By separating users, sessions, documents, questions, answers, and evaluations into different tables, the design reduces unnecessary duplication and makes relationships easier to manage.

The transformation from UNF to 1NF, 2NF, and 3NF removes repeating groups, partial dependencies, and transitive dependencies. BCNF provides an additional check to ensure that every determinant is a candidate key.

This proposed design provides a foundation for implementing the InterAct database in PostgreSQL. The final schema and functional dependencies will be verified when the application data model and database implementation are finalized.