import { useEffect, useState } from 'react';
import { Sidebar } from '../components/Sidebar';
import { userService, UserProfile, Family } from '../api/authService';

export const MainScreen = () => {
    const [profile, setProfile] = useState<UserProfile | null>(null);
    const [families, setFamilies] = useState<Family[]>([]);
    const [isLoading, setIsLoading] = useState(true);

    useEffect(() => {
        const loadInitialData = async () => {
            try {
                // Пытаемся загрузить данные, если один запрос упадет, приложение не должно «белеть»
                const profileRes = await userService.fetchProfile().catch(() => null);
                const familiesRes = await userService.fetchFamilies().catch(() => ({ data: [] }));

                if (profileRes) setProfile(profileRes.data);
                if (familiesRes) setFamilies(familiesRes.data);
            } catch (error) {
                console.error("Critical load error:", error);
            } finally {
                setIsLoading(false);
            }
        };

        loadInitialData();
    }, []);

    if (isLoading) {
        return (
            <div className="h-screen w-screen flex items-center justify-center bg-gray-900">
                <div className="animate-spin rounded-full h-12 w-12 border-t-2 border-b-2 border-blue-500"></div>
            </div>
        );
    }

    return (
        <div className="flex h-screen w-screen bg-gray-50 overflow-hidden">
            <Sidebar 
                fName={profile?.first_name || ''} 
                lName={profile?.last_name || ''} 
                families={families} 
            />
            <main className="flex-1 p-8 overflow-y-auto">
                <header className="mb-8">
                    <h1 className="text-3xl font-bold text-gray-800">
                        {profile?.first_name}, добро пожаловать!
                    </h1>
                </header>
            </main>
        </div>
    );
};