import streamlit as st
import pandas as pd
import os
import json
from datetime import datetime

# Fichiers de sauvegarde
CSV_FILE = 'historique_budget.csv'
CONFIG_FILE = 'config_participants.json'

st.set_page_config(page_title="Budget Vacances", page_icon="📝", layout="wide")

st.title("📝 Gestion Budget Vacances")

# --- 1. FONCTIONS ---

def load_data():
    if os.path.exists(CSV_FILE):
        return pd.read_csv(CSV_FILE)
    else:
        return pd.DataFrame(columns=["Date", "Description", "Montant"])

def save_dataframe(df):
    df.to_csv(CSV_FILE, index=False)

def clear_data():
    if os.path.exists(CSV_FILE):
        os.remove(CSV_FILE)

def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    else:
        return [
            {"nom": "Personne A", "salaire": 2000.0},
            {"nom": "Personne B", "salaire": 3000.0}
        ]

def save_config(participants):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(participants, f)

# --- 2. BARRE LATÉRALE ---
st.sidebar.header("👥 Participants")

if 'participants' not in st.session_state:
    st.session_state.participants = load_config()

col_add, col_del = st.sidebar.columns(2)
if col_add.button("➕ Pers."):
    st.session_state.participants.append({"nom": "Nouveau", "salaire": 1500.0})
    save_config(st.session_state.participants)
    st.rerun()

if col_del.button("➖ Pers.") and len(st.session_state.participants) > 0:
    st.session_state.participants.pop()
    save_config(st.session_state.participants)
    st.rerun()

total_revenus = 0
config_has_changed = False

for i, p in enumerate(st.session_state.participants):
    col1, col2 = st.sidebar.columns([2, 1.5])
    new_nom = col1.text_input(f"Nom {i+1}", p['nom'], key=f"n_{i}")
    new_sal = col2.number_input(f"Salaire", value=float(p['salaire']), step=100.0, key=f"s_{i}")

    if new_nom != p['nom'] or new_sal != p['salaire']:
        p['nom'] = new_nom
        p['salaire'] = new_sal
        config_has_changed = True
    total_revenus += p['salaire']

if config_has_changed:
    save_config(st.session_state.participants)

st.sidebar.divider()
st.sidebar.metric("Revenus Totaux", f"{total_revenus:,.0f} €")

# --- 3. AJOUT RAPIDE ---
st.subheader("➕ Ajouter une dépense")
with st.container(border=True):
    c1, c2, c3 = st.columns([2, 1, 1])
    input_desc = c1.text_input("Quoi ?", placeholder="Ex: Courses...", key="new_desc")
    input_montant = c2.number_input("Combien (€) ?", min_value=0.0, step=5.0, key="new_montant")

    c3.write("") # Espacement
    c3.write("")
    if c3.button("Enregistrer", use_container_width=True):
        if input_montant > 0 and input_desc:
            now = datetime.now().strftime("%d-%m %H:%M")
            # Chargement, ajout et sauvegarde
            df_current = load_data()
            new_row = pd.DataFrame({"Date": [now], "Description": [input_desc], "Montant": [input_montant]})
            df_updated = pd.concat([df_current, new_row], ignore_index=True)
            save_dataframe(df_updated)
            st.success("Ajouté !")
            import time
            time.sleep(0.5)
            st.rerun()

st.divider()

# --- 4. MODIFICATION & BILAN ---

df = load_data()

if not df.empty and total_revenus > 0:

    # --- ZONE DE MODIFICATION ---
    with st.expander("✏️ Modifier ou Supprimer des lignes", expanded=True):
        st.caption("Vous pouvez modifier les cases directement. Pour supprimer : sélectionnez une ligne et appuyez sur 'Suppr' (ou l'icône poubelle qui apparaît au survol).")

        # Le widget .data_editor permet l'édition directe
        edited_df = st.data_editor(
            df,
            num_rows="dynamic", # Permet d'ajouter/supprimer des lignes
            use_container_width=True,
            key="editor"
        )

        # Si l'utilisateur a modifié quelque chose, on sauvegarde
        if not df.equals(edited_df):
            save_dataframe(edited_df)
            st.rerun()

    st.divider()

    # --- ZONE DE CALCULS (LECTURE SEULE) ---
    st.subheader("📊 Répartition détaillée (Lecture seule)")

    # Copie pour affichage calculé
    df_view = edited_df.copy()
    totaux_par_personne = {p['nom']: 0.0 for p in st.session_state.participants}

    # Calcul des colonnes dynamiques
    for p in st.session_state.participants:
        part_pct = p['salaire'] / total_revenus

        # Ajout au total global de la personne
        totaux_par_personne[p['nom']] += df_view['Montant'].sum() * part_pct

        # Création de la colonne visuelle (facultatif, pour info)
        col_name = f"Part {p['nom']} ({part_pct*100:.0f}%)"
        df_view[col_name] = df_view['Montant'] * part_pct

    # Affichage du tableau calculé (non éditable ici)
    st.dataframe(
        df_view.iloc[::-1], # Ordre inversé pour voir les derniers en premier
        use_container_width=True,
        hide_index=True,
        column_config={"Montant": st.column_config.NumberColumn(format="%.2f €")}
    )

    # --- CARTES DE BILAN ---
    st.write("")
    st.subheader("💰 Bilan Total à Payer")

    cols = st.columns(len(st.session_state.participants))
    for idx, p in enumerate(st.session_state.participants):
        montant_a_payer = totaux_par_personne[p['nom']]
        with cols[idx]:
            st.info(f"**{p['nom']}** doit payer :\n\n### {montant_a_payer:.2f} €")

else:
    st.info("La liste est vide.")
