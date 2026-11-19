-- =============================================================================
-- InterAct: every query the application runs against PostgreSQL
-- =============================================================================
--
-- Source: the backend runs these through SQLAlchemy 2. The list was taken from
-- the SQL the app actually executes (every statement recorded while the full
-- backend test suite ran, compiled for PostgreSQL), then written out by hand
-- to be readable.
--
-- Conventions
--   -- READ / -- WRITE   marks every statement.
--   :name                 a bound parameter (the app never builds SQL from text).
--   "App:"                the backend function that runs it.
--   "JOIN form"           where the app loads rows one at a time, the equivalent
--                         single JOIN query is shown, and the comment says so.
--
-- Ownership: every user-facing query filters on owner_id (directly, or through
-- the owning session or document), so one user can never read another's rows.
-- Deletes rely on ON DELETE CASCADE foreign keys for child rows.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Users and sign-in
-- -----------------------------------------------------------------------------

-- READ: the signed-in user named in the session cookie.
-- App: api/deps.py get_optional_user (every request that needs a user).
SELECT id, auth_provider, provider_user_id, email, display_name, default_avatar_key, created_at
FROM users
WHERE id = :user_id;

-- READ: find the account for a Google / GitHub / dev sign-in.
-- App: services/accounts.py upsert_user. Uses UNIQUE (auth_provider, provider_user_id).
SELECT id, auth_provider, provider_user_id, email, display_name, default_avatar_key, created_at
FROM users
WHERE auth_provider = :auth_provider
  AND provider_user_id = :provider_user_id;

-- WRITE: first sign-in creates the account (only provider, provider id, email and name are stored).
-- App: services/accounts.py upsert_user.
INSERT INTO users (id, auth_provider, provider_user_id, email, display_name, default_avatar_key, created_at)
VALUES (:id, :auth_provider, :provider_user_id, :email, :display_name, NULL, now());

-- WRITE: a later sign-in keeps the stored email and name current.
-- App: services/accounts.py upsert_user.
UPDATE users
SET email = :email,
    display_name = :display_name
WHERE id = :user_id;


-- -----------------------------------------------------------------------------
-- 2. Interview sessions
-- -----------------------------------------------------------------------------

-- WRITE: start a new interview (state PREPARING).
-- App: services/interview.py create_session.
INSERT INTO sessions (id, owner_id, input_model, state, context_json, config_json, prepared_json, created_at, updated_at)
VALUES (:id, :owner_id, :input_model, 'PREPARING', NULL, NULL, NULL, now(), now());

-- READ: one of the user's sessions; another user's looks the same as a missing one.
-- App: services/interview.py get_session (nearly every session endpoint).
SELECT id, owner_id, input_model, state, context_json, config_json, prepared_json, created_at, updated_at
FROM sessions
WHERE id = :session_id
  AND owner_id = :owner_id;

-- READ: the same, locked, before a state change (answers, pause, finish...).
-- App: services/interview.py get_session(lock=True). Serialises parallel requests on one session.
SELECT id, owner_id, input_model, state, context_json, config_json, prepared_json, created_at, updated_at
FROM sessions
WHERE id = :session_id
  AND owner_id = :owner_id
FOR UPDATE;

-- READ: lock a session by id for the background task that writes the next question ahead.
-- App: services/interview.py prepare_next_question (runs after the response, no user in scope).
SELECT id, owner_id, input_model, state, context_json, config_json, prepared_json, created_at, updated_at
FROM sessions
WHERE id = :session_id
FOR UPDATE;

-- READ: interview history, newest first, with how many planned questions were asked and answered.
-- App: services/interview.py list_sessions + question_counts.
-- JOIN form: the app lists the sessions, then counts questions and answers per session;
-- this single query returns the same numbers. Follow-ups (follow_up > 0) are not counted.
SELECT s.id, s.input_model, s.state, s.context_json, s.config_json, s.created_at, s.updated_at,
       count(q.id)                                AS questions_asked,
       count(a.id)                                AS questions_answered
FROM sessions s
LEFT JOIN questions q ON q.session_id = s.id AND q.follow_up = 0
LEFT JOIN answers   a ON a.question_id = q.id
WHERE s.owner_id = :owner_id
GROUP BY s.id
ORDER BY s.created_at DESC;

-- READ: planned questions asked so far in one session (the question budget).
-- App: services/interview.py _planned_asked.
SELECT count(*)
FROM questions
WHERE session_id = :session_id
  AND follow_up = 0;

-- READ: planned questions answered so far in one session.
-- App: services/interview.py question_counts.
SELECT count(*)
FROM answers a
JOIN questions q ON q.id = a.question_id
WHERE a.session_id = :session_id
  AND q.follow_up = 0;

-- WRITE: save the interview's scope (topic, goal, level, subtopics, or the document and its topics),
-- moving PREPARING -> CONFIGURING the first time.
-- App: services/interview.py set_context; services/preparation.py send_message saves the draft.
UPDATE sessions
SET context_json = :context_json,
    state = :state,
    updated_at = now()
WHERE id = :session_id;

-- WRITE: save the shared settings (style, difficulty, count, adaptive).
-- App: services/interview.py set_config.
UPDATE sessions
SET config_json = :config_json,
    updated_at = now()
WHERE id = :session_id;

-- WRITE: every state change: confirm plan, start, answer, next question, pause, resume, finish.
-- App: services/interview.py _move (through confirm_plan, start, submit_answer, _advance, pause, resume, finish).
UPDATE sessions
SET state = :state,
    updated_at = now()
WHERE id = :session_id;

-- WRITE: keep (or clear) the next question written ahead in the background.
-- App: services/interview.py prepare_next_question, _advance.
UPDATE sessions
SET prepared_json = :prepared_json,
    updated_at = now()
WHERE id = :session_id;


-- -----------------------------------------------------------------------------
-- 3. Model A clarification chat
-- -----------------------------------------------------------------------------

-- READ: the chat so far, in order.
-- App: services/preparation.py _messages.
SELECT m.id, m.position, m.role, m.kind, m.content, m.created_at
FROM preparation_messages m
JOIN sessions s ON s.id = m.session_id
WHERE m.session_id = :session_id
  AND s.owner_id = :owner_id
ORDER BY m.position;

-- READ: the next position in the chat.
-- App: services/preparation.py _add.
SELECT coalesce(max(position), 0) + 1 AS next_position
FROM preparation_messages
WHERE session_id = :session_id;

-- WRITE: a request, reply or skip from the candidate, or a question or summary from the planner.
-- App: services/preparation.py _add. UNIQUE (session_id, position) keeps the order.
INSERT INTO preparation_messages (id, session_id, position, role, kind, content, created_at)
VALUES (:id, :session_id, :position, :role, :kind, :content, now());


-- -----------------------------------------------------------------------------
-- 4. Questions and answers during the call
-- -----------------------------------------------------------------------------

-- READ: every question in a session, planned questions with their follow-ups.
-- App: services/interview.py _questions; services/reporting.py build_report.
SELECT id, session_id, sequence, follow_up, lead_in, type, competency, difficulty, prompt, rubric_id,
       source_chunk_ids, supporting_quote, answer_key_json, grounding_status, grounding_note,
       style_status, style_note, created_at
FROM questions
WHERE session_id = :session_id
ORDER BY sequence, follow_up;

-- READ: the one question still waiting for an answer (a question with no answer row).
-- App: services/interview.py _unanswered, current_question.
SELECT q.id, q.sequence, q.follow_up, q.lead_in, q.type, q.competency, q.difficulty, q.prompt,
       q.source_chunk_ids, q.grounding_status
FROM questions q
LEFT JOIN answers a ON a.question_id = q.id
WHERE q.session_id = :session_id
  AND a.id IS NULL
ORDER BY q.sequence, q.follow_up
LIMIT 1;

-- READ: the question being answered, only if it belongs to this session.
-- App: services/interview.py _save_answer.
SELECT id, session_id, sequence, follow_up, type, competency, difficulty, prompt, rubric_id
FROM questions
WHERE id = :question_id
  AND session_id = :session_id;

-- READ: a question by id (for scoring and the interviewer's reply).
-- App: services/interview.py _evaluate, _advance.
SELECT id, session_id, sequence, follow_up, type, competency, difficulty, prompt, rubric_id,
       source_chunk_ids, supporting_quote, answer_key_json, grounding_status
FROM questions
WHERE id = :question_id;

-- READ: a planned question and its follow-ups, each with its answer: the conversation the
-- interviewer reacts to and that is scored together.
-- App: services/interview.py _exchange.
SELECT q.id, q.follow_up, q.prompt, a.id AS answer_id, a.text AS answer_text
FROM questions q
JOIN answers a ON a.question_id = q.id
WHERE q.session_id = :session_id
  AND q.sequence = :sequence
ORDER BY q.follow_up;

-- READ: whether a question already has an answer (a resubmission must not create a second one).
-- App: services/interview.py submit_answer, _save_answer, _advance.
SELECT id, question_id, session_id, text, submitted_at, reaction, delivery_json
FROM answers
WHERE question_id = :question_id;

-- READ: an answer by id.
-- App: services/interview.py _evaluate, _insufficient_reason.
SELECT id, question_id, session_id, text, submitted_at, reaction, delivery_json
FROM answers
WHERE id = :answer_id;

-- WRITE: a planned question (budget) or a follow-up (same sequence, follow_up 1 or 2).
-- App: services/interview.py _add_question (start, _advance) and the follow-up branch of _advance.
INSERT INTO questions (id, session_id, sequence, follow_up, lead_in, type, competency, difficulty, prompt, rubric_id,
                       source_chunk_ids, supporting_quote, answer_key_json, grounding_status, grounding_note,
                       style_status, style_note, created_at)
VALUES (:id, :session_id, :sequence, :follow_up, :lead_in, :type, :competency, :difficulty, :prompt, :rubric_id,
        :source_chunk_ids, :supporting_quote, :answer_key_json, :grounding_status, :grounding_note,
        :style_status, :style_note, now());

-- WRITE: the candidate's answer, with delivery and focus numbers (never media).
-- App: services/interview.py _save_answer. UNIQUE (question_id): one answer per question.
INSERT INTO answers (id, question_id, session_id, text, submitted_at, reaction, delivery_json)
VALUES (:id, :question_id, :session_id, :text, now(), NULL, :delivery_json);

-- WRITE: what the interviewer said in reply, so a repeated submit gets the same reply.
-- App: services/interview.py _advance (keep_reaction).
UPDATE answers
SET reaction = :reaction
WHERE id = :answer_id
  AND reaction IS NULL;


-- -----------------------------------------------------------------------------
-- 5. Rubrics, model calls, scoring and the report
-- -----------------------------------------------------------------------------

-- READ: the stored rubric version for a question style.
-- App: services/interview.py _rubric_row.
SELECT id, name, version, criteria_json, max_score, created_at
FROM rubrics
WHERE name = :name
  AND version = :version;

-- WRITE: store a rubric version the first time it is used (never edited afterwards).
-- App: services/interview.py _rubric_row. UNIQUE (name, version).
INSERT INTO rubrics (id, name, version, criteria_json, max_score, created_at)
VALUES (:id, :name, :version, :criteria_json, :max_score, now());

-- WRITE: every model call, valid or not, stored raw against its session or document.
-- App: services/interview.py _record_llm_call. CHECK: session_id or document_id is set.
INSERT INTO llm_calls (id, session_id, document_id, purpose, model, prompt_version, raw_output, validation_status, created_at)
VALUES (:id, :session_id, :document_id, :purpose, :model, :prompt_version, :raw_output, :validation_status, now());

-- READ: planned answers not yet scored, in order (finishing again continues where scoring stopped).
-- App: services/interview.py _score_answers.
SELECT a.id, a.question_id, a.text
FROM answers a
JOIN questions q        ON q.id = a.question_id
LEFT JOIN evaluations e ON e.answer_id = a.id
WHERE a.session_id = :session_id
  AND q.follow_up = 0
  AND e.id IS NULL
ORDER BY q.sequence;

-- READ: the question's rubric while scoring.
-- App: services/interview.py _evaluate.
SELECT id, name, version, criteria_json, max_score
FROM rubrics
WHERE id = :rubric_id;

-- WRITE: a validated score with its checked evidence quotes.
-- App: services/interview.py _evaluate. UNIQUE (answer_id): one evaluation per answer.
INSERT INTO evaluations (id, answer_id, scores_json, evidence_json, evaluator_version, created_at)
VALUES (:id, :answer_id, :scores_json, :evidence_json, :evaluator_version, now());

-- READ: everything the report is built from: each question with its answer and score.
-- App: services/reporting.py build_report.
-- JOIN form: the app loads the questions, then each one's answer and evaluation in turn;
-- this single query returns the same rows.
SELECT q.sequence, q.follow_up, q.type, q.competency, q.difficulty, q.prompt,
       q.answer_key_json, q.supporting_quote, q.source_chunk_ids, q.grounding_status, q.grounding_note,
       q.style_status,
       a.text           AS answer_text,
       a.delivery_json,
       e.scores_json,
       e.evidence_json
FROM questions q
LEFT JOIN answers a     ON a.question_id = q.id
LEFT JOIN evaluations e ON e.answer_id = a.id
WHERE q.session_id = :session_id
ORDER BY q.sequence, q.follow_up;

-- READ: the delivery and focus numbers of every answer, for the report's separate section.
-- App: services/reporting.py build_report.
SELECT delivery_json
FROM answers
WHERE session_id = :session_id
  AND delivery_json IS NOT NULL;

-- READ: the pages a document question cites, for the report.
-- App: services/reporting.py _sources.
-- JOIN form: the app looks up each cited chunk by id; the ids are stored in questions.source_chunk_ids (JSONB).
SELECT q.sequence, c.page, c.page_end, c.page_starts, c.text
FROM questions q
CROSS JOIN LATERAL jsonb_array_elements_text(q.source_chunk_ids) AS cited(chunk_id)
JOIN document_chunks c ON c.id = cited.chunk_id::uuid
WHERE q.session_id = :session_id;

-- WRITE: the final report.
-- App: services/interview.py _write_report (from finish). UNIQUE (session_id): one report per session.
INSERT INTO reports (id, session_id, summary_json, generated_at)
VALUES (:id, :session_id, :summary_json, now());

-- READ: the user's report.
-- App: services/interview.py get_report.
SELECT r.id, r.session_id, r.summary_json, r.generated_at
FROM reports r
JOIN sessions s ON s.id = r.session_id
WHERE r.session_id = :session_id
  AND s.owner_id = :owner_id;


-- -----------------------------------------------------------------------------
-- 6. Documents (Model B)
-- -----------------------------------------------------------------------------

-- WRITE: an uploaded file, stored on disk under a random storage_key.
-- App: services/documents.py upload.
INSERT INTO documents (id, owner_id, filename, storage_key, status, summary_json, created_at)
VALUES (:id, :owner_id, :filename, :storage_key, 'UPLOADED', NULL, now());

-- READ: one of the user's documents.
-- App: services/documents.py get_document; services/interview.py _check_context.
SELECT id, owner_id, filename, storage_key, status, summary_json, created_at
FROM documents
WHERE id = :document_id
  AND owner_id = :owner_id;

-- READ: a document by id, in the background processing task.
-- App: api/documents.py _process_later; services/documents.py process.
SELECT id, owner_id, filename, storage_key, status, summary_json, created_at
FROM documents
WHERE id = :document_id;

-- READ: the user's uploads, newest first, each with its latest processing job.
-- App: services/documents.py list_documents + services/jobs.py latest_job.
-- JOIN form: the app lists the documents, then fetches each one's latest job.
SELECT d.id, d.filename, d.status, d.summary_json, d.created_at, j.id AS job_id, j.status AS job_status
FROM documents d
LEFT JOIN LATERAL (
    SELECT id, status
    FROM jobs
    WHERE jobs.document_id = d.id
    ORDER BY created_at DESC
    LIMIT 1
) j ON true
WHERE d.owner_id = :owner_id
ORDER BY d.created_at DESC;

-- WRITE: processing starts, ends READY with a summary, or ends FAILED with the reason.
-- App: services/documents.py process, _fail; api/documents.py _process_later.
UPDATE documents
SET status = :status,
    summary_json = :summary_json
WHERE id = :document_id;

-- WRITE: replace a document's chunks (processing again never duplicates them).
-- App: services/documents.py save_chunks.
DELETE FROM document_chunks
WHERE document_id = :document_id;

-- WRITE: one page-aware chunk.
-- App: services/documents.py save_chunks. UNIQUE (document_id, chunk_index).
INSERT INTO document_chunks (id, document_id, chunk_index, page, page_end, page_starts, text)
VALUES (:id, :document_id, :chunk_index, :page, :page_end, :page_starts, :text);

-- READ: a document's chunks in order.
-- App: services/documents.py topics_of; services/interview.py _passages, _document_scope.
SELECT id, chunk_index, page, page_end, page_starts, text
FROM document_chunks
WHERE document_id = :document_id
ORDER BY chunk_index;

-- READ: one chunk by id (a question's cited source, while scoring).
-- App: services/interview.py _evaluate.
SELECT id, document_id, chunk_index, page, page_end, page_starts, text
FROM document_chunks
WHERE id = :chunk_id;

-- WRITE: replace a document's topic map.
-- App: services/documents.py map_topics.
DELETE FROM document_topics
WHERE document_id = :document_id;

-- WRITE: one topic of the map, with the ids of the chunks that cover it.
-- App: services/documents.py map_topics.
INSERT INTO document_topics (id, document_id, name, summary, chunk_ids)
VALUES (:id, :document_id, :name, :summary, :chunk_ids);

-- READ: the topic map with each topic's chunks, for the review screen and the interview scope.
-- App: services/documents.py topics_of; services/interview.py _check_context, _document_scope.
-- JOIN form: the app loads the topics and the chunks, then matches chunk ids in Python.
SELECT t.id AS topic_id, t.name, t.summary, c.id AS chunk_id, c.chunk_index, c.page, c.page_end, c.page_starts, c.text
FROM document_topics t
JOIN documents d ON d.id = t.document_id
CROSS JOIN LATERAL jsonb_array_elements_text(t.chunk_ids) AS cited(chunk_id)
JOIN document_chunks c ON c.id = cited.chunk_id::uuid
WHERE t.document_id = :document_id
  AND d.owner_id = :owner_id
ORDER BY c.chunk_index, t.name;

-- READ: the topic a question is about (its mapped chunks are the question's passages).
-- App: services/interview.py _passages.
SELECT id, name, summary, chunk_ids
FROM document_topics
WHERE document_id = :document_id
  AND name = :competency;


-- -----------------------------------------------------------------------------
-- 7. Background jobs
-- -----------------------------------------------------------------------------

-- WRITE: queue processing for a document.
-- App: services/jobs.py queue_processing.
INSERT INTO jobs (id, owner_id, kind, status, session_id, document_id, result_json, error_code, completed_at, created_at)
VALUES (:id, :owner_id, 'process_document', 'QUEUED', NULL, :document_id, NULL, NULL, NULL, now());

-- READ: the latest job for a document (to refuse a second one while it runs).
-- App: services/jobs.py latest_job.
SELECT id, kind, status, document_id, result_json, error_code, created_at, completed_at
FROM jobs
WHERE document_id = :document_id
ORDER BY created_at DESC
LIMIT 1;

-- READ: a job's status, polled by the browser; only the owner's.
-- App: services/jobs.py get_job.
SELECT id, kind, status, document_id, result_json, error_code, created_at, completed_at
FROM jobs
WHERE id = :job_id
  AND owner_id = :owner_id;

-- READ: a job by id in the background task.
-- App: api/documents.py _process_later.
SELECT id, owner_id, kind, status, document_id, created_at
FROM jobs
WHERE id = :job_id;

-- WRITE: the job starts.
-- App: services/jobs.py start.
UPDATE jobs
SET status = 'PROCESSING'
WHERE id = :job_id;

-- WRITE: the job ends (COMPLETED, or FAILED with a code such as 'interrupted').
-- App: services/jobs.py finish.
UPDATE jobs
SET status = :status,
    result_json = :result_json,
    error_code = :error_code,
    completed_at = now()
WHERE id = :job_id;


-- -----------------------------------------------------------------------------
-- 8. Retention and deletion of uploads
-- -----------------------------------------------------------------------------

-- READ: whether an unfinished interview still uses a document (then it must be kept).
-- App: services/documents.py in_use.
SELECT EXISTS (
    SELECT 1
    FROM sessions s
    WHERE s.owner_id = :owner_id
      AND s.input_model = 'DOCUMENT'
      AND s.state <> 'COMPLETED'
      AND s.context_json ->> 'document_id' = :document_id::text
) AS in_use;

-- READ: uploads past the retention period that no unfinished interview uses.
-- App: services/documents.py purge_expired.
-- JOIN form: the app loads every document and checks age and use in Python.
SELECT d.id, d.storage_key
FROM documents d
WHERE d.created_at <= now() - make_interval(days => :retention_days)
  AND NOT EXISTS (
      SELECT 1
      FROM sessions s
      WHERE s.owner_id = d.owner_id
        AND s.input_model = 'DOCUMENT'
        AND s.state <> 'COMPLETED'
        AND s.context_json ->> 'document_id' = d.id::text
  );

-- WRITE: delete a document. ON DELETE CASCADE also deletes its chunks, topic map, jobs and
-- model calls; the stored file is removed by the app after the commit.
-- App: services/documents.py delete_document (DELETE /documents/{id}, and purge_expired).
DELETE FROM documents
WHERE id = :document_id
  AND owner_id = :owner_id;
