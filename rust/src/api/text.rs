use std::path::Path;
use std::sync::{Mutex, RwLock};

use tantivy::collector::TopDocs;
use tantivy::query::QueryParser;
use tantivy::schema::{
    Field, NumericOptions, Schema, TextFieldIndexing, TextOptions, Value,
};
use tantivy::tokenizer::{Language, LowerCaser, RemoveLongFilter, SimpleTokenizer, Stemmer, TextAnalyzer};
use tantivy::{doc, DocAddress, Index, IndexReader, IndexWriter, ReloadPolicy, TantivyDocument, Term};

use anyhow::{Result, anyhow};
use crate::api::schema::WaffleLanguage;

const TOKENIZER_NAME: &str = "waffle_txt";
const WRITER_HEAP_BYTES: usize = 50_000_000;

fn analyzer_for(language: &WaffleLanguage) -> TextAnalyzer {
    let stemmer = match language {
        WaffleLanguage::English => Stemmer::new(Language::English),
        WaffleLanguage::Arabic => Stemmer::new(Language::Arabic),
    };
    TextAnalyzer::builder(SimpleTokenizer::default())
        .filter(RemoveLongFilter::limit(40))
        .filter(LowerCaser)
        .filter(stemmer)
        .build()
}

pub(crate) struct TextEngine {
    index: Index,
    writer: Mutex<IndexWriter>,
    reader: IndexReader,
    parser_fields: RwLock<Vec<Field>>,
    f_text: Field,
    f_wid: Field,
}

impl TextEngine {
    pub(crate) fn open(dir: &Path, language: &WaffleLanguage) -> Result<Self> {
        std::fs::create_dir_all(dir)
            .map_err(|e| anyhow!("cannot create tantivy dir: {e}"))?;
        let mut schema_builder = Schema::builder();
        let text_options = TextOptions::default()
            .set_indexing_options(
                TextFieldIndexing::default().set_tokenizer(TOKENIZER_NAME),
            )
            .set_stored();
        let f_text = schema_builder.add_text_field("text", text_options);
        let f_wid = schema_builder.add_u64_field(
            "wid",
            NumericOptions::default().set_indexed().set_stored(),
        );
        let schema = schema_builder.build();

        let meta_path = dir.join("meta.json");
        let index = if meta_path.exists() {
            Index::open_in_dir(dir)?
        } else {
            Index::create_in_dir(dir, schema)?
        };
        index
            .tokenizers()
            .register(TOKENIZER_NAME, analyzer_for(language));

        let writer = index.writer_with_num_threads(1, WRITER_HEAP_BYTES)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        Ok(Self {
            index,
            writer: Mutex::new(writer),
            reader,
            parser_fields: RwLock::new(vec![f_text]),
            f_text,
            f_wid,
        })
    }

    pub(crate) fn add(&self, internal: u32, text: &str) -> Result<()> {
        if text.trim().is_empty() {
            return Ok(());
        }
        let writer = self
            .writer
            .lock()
            .map_err(|e| anyhow!("writer lock poisoned: {e}"))?;
        writer.add_document(doc!(
            self.f_text => text,
            self.f_wid => internal as u64
        ))?;
        Ok(())
    }

    pub(crate) fn delete(&self, internal: u32) -> Result<()> {
        let writer = self
            .writer
            .lock()
            .map_err(|e| anyhow!("writer lock poisoned: {e}"))?;
        writer.delete_term(Term::from_field_u64(self.f_wid, internal as u64));
        Ok(())
    }

    pub(crate) fn commit(&self) -> Result<()> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|e| anyhow!("writer lock poisoned: {e}"))?;
        writer.commit()?;
        drop(writer);
        self.reader.reload()?;
        Ok(())
    }

    pub(crate) fn search(&self, text: &str, k: usize) -> Result<Vec<(u32, f32)>> {
        if k == 0 || text.trim().is_empty() {
            return Ok(Vec::new());
        }
        let fields = self
            .parser_fields
            .read()
            .map_err(|e| anyhow!("lock poisoned: {e}"))?
            .clone();
        let parser = QueryParser::for_index(&self.index, fields);
        let query = parser.parse_query(text)?;
        let searcher = self.reader.searcher();
        let top: Vec<(f32, DocAddress)> =
            searcher.search(&query, &TopDocs::with_limit(k).order_by_score())?;
        let mut out = Vec::with_capacity(top.len());
        for (score, addr) in top {
            let stored: TantivyDocument = searcher.doc(addr)?;
            if let Some(wid) = stored
                .get_first(self.f_wid)
                .and_then(|v| v.as_u64())
            {
                out.push((wid as u32, score));
            }
        }
        Ok(out)
    }
}
