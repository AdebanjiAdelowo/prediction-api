from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    model_path: str = "model.pt"
    model_version: str = "1.0.0"
    model_input_dim: int = 4
    model_num_classes: int = 3
    database_url: str = "postgresql://postgres:postgres@localhost:5432/predictions"

    model_config = {"env_file": ".env"}


settings = Settings()
