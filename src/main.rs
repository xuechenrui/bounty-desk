use anyhow::{Context, Result};
use bounty_desk::{
    settle, verify_transaction, Cluster, InvoiceStatus, InvoiceStore, NewInvoice, RpcClient,
    DEFAULT_USDC_DECIMALS,
};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Parser)]
#[command(name = "bounty-desk", version, about)]
struct Cli {
    #[arg(long, global = true, default_value = "invoices.json")]
    db: PathBuf,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create a keyless Solana Pay SPL-token invoice.
    Create {
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        amount: String,
        #[arg(long)]
        token_mint: String,
        #[arg(long, default_value_t = DEFAULT_USDC_DECIMALS)]
        decimals: u8,
        #[arg(long, value_enum, default_value_t = Network::MainnetBeta)]
        network: Network,
        #[arg(long)]
        id: Option<String>,
        #[arg(long, default_value = "BountyDesk")]
        label: String,
        #[arg(long, default_value = "Freelance bounty payment")]
        message: String,
    },
    /// Query and reconcile one invoice against Solana RPC.
    Status {
        #[arg(long)]
        id: String,
        #[arg(long)]
        rpc_url: Option<String>,
    },
    /// Reconcile every pending invoice. This never signs or sends a transaction.
    Reconcile {
        #[arg(long)]
        rpc_url: Option<String>,
    },
    /// List local invoices without contacting the network.
    List,
    /// Verify a captured parsed transaction against explicit invoice invariants.
    VerifyFixture {
        #[arg(long)]
        file: PathBuf,
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        token_mint: String,
        #[arg(long)]
        reference: String,
        #[arg(long)]
        amount_units: u64,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Network {
    MainnetBeta,
    Devnet,
}

impl From<Network> for Cluster {
    fn from(network: Network) -> Self {
        match network {
            Network::MainnetBeta => Self::MainnetBeta,
            Network::Devnet => Self::Devnet,
        }
    }
}

fn main() {
    if let Err(error) = run() {
        let payload = json!({
            "ok": false,
            "error": format!("{error:#}"),
        });
        eprintln!("{}", serde_json::to_string_pretty(&payload).unwrap());
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Create {
            recipient,
            amount,
            token_mint,
            decimals,
            network,
            id,
            label,
            message,
        } => {
            let invoice = NewInvoice {
                id,
                recipient,
                amount,
                decimals,
                token_mint,
                label,
                message,
                cluster: network.into(),
            }
            .build()?;
            let mut store = InvoiceStore::load(&cli.db)?;
            store.add(invoice.clone())?;
            store.save(&cli.db)?;
            print_json(&json!({"ok": true, "invoice": invoice}))
        }
        Command::Status { id, rpc_url } => {
            let mut store = InvoiceStore::load(&cli.db)?;
            let invoice = store
                .invoices
                .iter_mut()
                .find(|invoice| invoice.id == id)
                .with_context(|| format!("invoice not found: {id}"))?;
            let rpc =
                RpcClient::new(rpc_url.unwrap_or_else(|| invoice.cluster.rpc_url().to_owned()))?;
            let proof = settle(invoice, &rpc)?;
            let invoice = invoice.clone();
            store.save(&cli.db)?;
            print_json(&json!({
                "ok": true,
                "paid": invoice.status == InvoiceStatus::Paid,
                "invoice": invoice,
                "proof": proof,
            }))
        }
        Command::Reconcile { rpc_url } => {
            let mut store = InvoiceStore::load(&cli.db)?;
            let mut checked = 0_u64;
            let mut newly_paid = Vec::new();
            for invoice in store
                .invoices
                .iter_mut()
                .filter(|invoice| invoice.status == InvoiceStatus::Pending)
            {
                checked += 1;
                let endpoint = rpc_url
                    .clone()
                    .unwrap_or_else(|| invoice.cluster.rpc_url().to_owned());
                let rpc = RpcClient::new(endpoint)?;
                if let Some(proof) = settle(invoice, &rpc)? {
                    newly_paid.push(json!({
                        "id": invoice.id,
                        "signature": proof.signature,
                        "amount_received_units": proof.amount_received_units,
                    }));
                }
            }
            store.save(&cli.db)?;
            print_json(&json!({
                "ok": true,
                "checked": checked,
                "newly_paid": newly_paid,
                "note": "No transaction was signed or sent.",
            }))
        }
        Command::List => {
            let store = InvoiceStore::load(&cli.db)?;
            print_json(&json!({"ok": true, "invoices": store.invoices}))
        }
        Command::VerifyFixture {
            file,
            recipient,
            token_mint,
            reference,
            amount_units,
        } => {
            let transaction = read_json(&file)?;
            let proof = verify_transaction(
                &transaction,
                &recipient,
                &token_mint,
                &reference,
                amount_units,
            )?;
            let proof = proof.ok_or_else(|| {
                anyhow::anyhow!("fixture failed closed: invoice invariants were not satisfied")
            })?;
            print_json(&json!({
                "ok": true,
                "verified": true,
                "evidence": {
                    "slot": proof.slot,
                    "block_time": proof.block_time,
                    "amount_received_units": proof.amount_received_units,
                }
            }))
        }
    }
}

fn read_json(path: &Path) -> Result<Value> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read fixture {}", path.display()))?;
    serde_json::from_str(&raw).with_context(|| format!("invalid JSON fixture {}", path.display()))
}

fn print_json(value: &impl Serialize) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}
