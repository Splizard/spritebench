import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import os
import glob

def prettify_label(label):
    # Remove the _20000 part
    label = label.replace("_20000", "")
    
    parts = label.split("_")
    name_map = {
        "cs": "C#",
        "gds": "GDScript",
        "graphicsgd": "GraphicsGD",
        "rustbalanced": "Rust (Balanced)",
        "rustdisengaged": "Rust (Disengaged)"
    }
    
    name = name_map.get(parts[0], parts[0].capitalize())
    
    # Determine the variant
    if "html5" in parts:
        variant = "HTML5"
    elif "forwardplus" in parts:
        variant = "Forward+"
    else:
        variant = "Compatibility"
    
    return name, variant

def main():
    # Use absolute path for safety
    dir_path = os.path.dirname(os.path.realpath(__file__))
    csv_files = glob.glob(os.path.join(dir_path, "*.csv"))
    data = []

    for file_path in csv_files:
        file_name = os.path.basename(file_path)
        
        # Skip empty files
        if os.path.getsize(file_path) == 0:
            print(f"Skipping empty file: {file_name}")
            continue

        label = file_name.replace(".csv", "")
        name, variant = prettify_label(label)
        
        try:
            # The CSVs have no header and one column of frame times
            df = pd.read_csv(file_path, header=None)
            
            # Filter out zeros/negatives to avoid division by zero
            df = df[df[0] > 0]
            
            if not df.empty:
                fps_values = 1.0 / df[0]
                for fps in fps_values:
                    data.append({"Implementation": name, "Variant": variant, "FPS": fps})
            else:
                print(f"Warning: No valid frame times in {file_name}")
        except Exception as e:
            print(f"Error reading {file_name}: {e}")

    if not data:
        print("No valid data found in CSV files.")
        return

    plot_df = pd.DataFrame(data)
    
    # Calculate sort order based on mean FPS for Compatibility renderer only
    compat_df = plot_df[plot_df["Variant"] == "Compatibility"]
    sort_order = compat_df.groupby("Implementation")["FPS"].mean().sort_values(ascending=False).index
    
    # Define variant order
    variant_order = ["Compatibility", "Forward+", "HTML5"]
    
    sns.set_theme()
    
    # Set the style
    plt.figure(figsize=(10, 5.6))
    
    # Create the grouped bar plot
    ax = sns.barplot(
        x="Implementation", 
        y="FPS", 
        hue="Variant",
        data=plot_df, 
        order=sort_order,
        hue_order=variant_order,
        errorbar="sd",
        capsize=0.1
    )
    
    # Add labels to bars (showing the mean)
    for container in ax.containers:
        ax.bar_label(container, padding=5, fmt='%.1f', fontweight='bold', fontsize=8, label_type="center")
    
    plt.title("SpriteBench Performance Comparison (20,000 Sprites)", fontsize=16, pad=20)
    plt.xlabel("Implementation", fontsize=12)
    plt.ylabel("Average FPS (Higher is Better, Error Bars = SD)", fontsize=12)
    plt.legend(title="Renderer", loc="upper right")
    
    # Adjust layout and save
    plt.tight_layout()
    output_path = os.path.join(dir_path, "benchmark_results.svg")
    plt.savefig(output_path)
    print(f"Plot saved to {output_path}")
    
    # Show the plot if possible (might not work in headless environment)
    try:
        plt.show()
    except Exception:
        pass

if __name__ == "__main__":
    main()
